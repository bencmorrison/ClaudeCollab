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
#   bash install.sh --ref <tag|branch> install that ref instead of the latest release
#   bash install.sh --uninstall [--dest <dir>]   remove it again
#   bash install.sh --global           install user-level: scripts into ~/.claude/collab,
#                                       slash commands into ~/.claude/commands/collab
#                                       (invocations rewritten to absolute paths), agent
#                                       defs into the opencode global agent dir
#                                       ($XDG_CONFIG_HOME/opencode/agent). No .gitignore
#                                       (home isn't a repo). Incompatible with --dest.
#   bash install.sh --global --uninstall         remove the global install
#   bash install.sh --help
#
# Source of the files:
#   • Run from a clone: copies from the clone it lives in, as-is.
#   • Piped (curl … | bash): git-clones the repo into a temp dir first, at the
#     LATEST RELEASE TAG — not the default branch, which is development tip.
#   • --ref <tag|branch> (or CLAUDECOLLAB_REF) pins an exact ref: --ref v0.1.0
#     for a specific release, --ref main to track development. It always fetches
#     from the remote, even when this script is run from a clone.
#   • Override the URL with CLAUDECOLLAB_REPO=<git-url>.
set -euo pipefail

REPO_URL="${CLAUDECOLLAB_REPO:-https://github.com/bencmorrison/ClaudeCollab.git}"
REF="${CLAUDECOLLAB_REF:-}"               # empty = resolve the latest release tag

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
action="install"; dest="$PWD"; global=""; dest_explicit=""
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) action="uninstall" ;;
    --global) global=1 ;;
    --dest) shift; dest="${1:?--dest needs a directory}"; dest_explicit=1 ;;
    --dest=*) dest="${1#--dest=}"; dest_explicit=1 ;;
    --ref) shift; REF="${1:?--ref needs a tag or branch}" ;;
    --ref=*) REF="${1#--ref=}" ;;
    -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done

# --global installs into ~/.claude + the opencode global agent dir, NOT a project,
# so a destination directory is meaningless there. Reject the combination loudly
# rather than silently ignoring one.
if [ -n "$global" ] && [ -n "$dest_explicit" ]; then
  echo "install.sh: --global and --dest are incompatible (--global targets ~/.claude and the opencode global agent dir)." >&2
  exit 2
fi

say()  { printf '\033[36m•\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Resolve --dest to its real path, FOLLOWING any symlink in the prefix rather than
# refusing it. This used to `die` on a symlinked destination component, which broke
# macOS outright: /tmp -> /private/tmp and /var -> /private/var are OS-level
# symlinks, so `cd /tmp/proj && curl … | bash` — and any project under a symlinked
# mount — was rejected with a message that reads like a bug. The user NAMED --dest,
# so following it is honouring intent, not an escape; `into: $dest` below reports
# the resolved path so a redirect is never silent. The real write-time protection is
# unchanged and lives elsewhere: safe_dest_rel independently checks every path
# component UNDER $dest, per payload file, and still refuses a symlink there (so a
# payload file or a planted intermediate dir cannot redirect a write outside $dest).
# A dangling or non-directory prefix fails naturally in mkdir -p / cd below.
mkdir -p "$dest" 2>/dev/null || die "cannot create destination directory: $dest"
dest="$(cd "$dest" 2>/dev/null && pwd -P)" || die "cannot resolve destination directory: $dest"

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

# ============================ GLOBAL (user-level) =============================
# A SEPARATE branch from the per-project path above. It never touches $dest, the
# per-project manifest/hashes/state, or the .gitignore block. Its ownership records
# live in DISTINCT files (.install-manifest.global / .install-hashes.global) keyed
# by RESOLVED ABSOLUTE path, so the two layouts never read each other's records and
# uninstalling one can never delete the other's files.
#
# Two roots, derived PURELY from the environment so a test can sandbox the whole run
# with HOME=$tmp XDG_CONFIG_HOME=$tmp/.config and nothing lands under the real home:
#   CLAUDE_DIR         = $HOME/.claude                         (scripts -> its collab/)
#   OPENCODE_AGENT_DIR = ${XDG_CONFIG_HOME:-$HOME/.config}/opencode/agent  (agent defs)
# Both are resolved to a PHYSICAL path (following a dotfiles symlink like
# ~/.claude -> ~/.dotfiles/common/.claude), reusing the same mkdir+`cd … && pwd -P`
# follow-the-symlink pattern the --dest resolver uses. $CLAUDE_CONFIG_DIR is
# deliberately NOT honoured (PLAN.md scorecard item 6: undocumented, treat as absent).
CLAUDE_DIR=""; OPENCODE_AGENT_DIR=""; GMANIFEST=""; GHASHES=""
G_UROOT=""; G_UREL=""; G_ROOT=""; G_REL=""; G_ABS=""
gh_old=""; gm_new=""; gh_new=""

g_resolve_roots() {  # <create|nocreate>
  local create="$1"
  [ -n "${HOME:-}" ] || die "--global needs \$HOME to be set."
  CLAUDE_DIR="$HOME/.claude"
  OPENCODE_AGENT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/agent"
  if [ "$create" = create ]; then
    mkdir -p "$CLAUDE_DIR" 2>/dev/null || die "cannot create Claude config dir: $CLAUDE_DIR"
    mkdir -p "$OPENCODE_AGENT_DIR" 2>/dev/null || die "cannot create opencode agent dir: $OPENCODE_AGENT_DIR"
  fi
  # Resolve physical only where the dir exists (uninstall may run with neither).
  if [ -d "$CLAUDE_DIR" ]; then
    CLAUDE_DIR="$(cd "$CLAUDE_DIR" 2>/dev/null && pwd -P)" || die "cannot resolve Claude config dir: $CLAUDE_DIR"
  fi
  if [ -d "$OPENCODE_AGENT_DIR" ]; then
    OPENCODE_AGENT_DIR="$(cd "$OPENCODE_AGENT_DIR" 2>/dev/null && pwd -P)" || die "cannot resolve opencode agent dir: $OPENCODE_AGENT_DIR"
  fi
}

# Validate every component of <rel> UNDER <root>, refusing a symlink anywhere along
# it — the multi-root analogue of safe_dest_rel. A payload file or a planted
# intermediate dir cannot redirect a write outside the resolved root.
safe_under_root() {  # <root> <rel>
  local root="$1" rel="$2" cur="$1" part rest last
  valid_rel "$rel" || die "refusing unsafe global path: $rel"
  rest="$rel"
  while :; do
    case "$rest" in
      */*) part=${rest%%/*}; rest=${rest#*/}; last=false ;;
      *) part=$rest; last=true ;;
    esac
    cur="$cur/$part"
    [ -L "$cur" ] && die "refusing global destination symlink: $root/$rel"
    $last && break
  done
  return 0
}

# Map a payload rel to its global destination. Agent defs go FLAT into the opencode
# global agent dir (basename only); collab/** scripts preserve their sub-path under
# CLAUDE_DIR; the collab/ slash commands go to CLAUDE_DIR/commands/collab/ (Claude Code
# reads user-level commands there, namespaced /collab:<name> exactly as per-project).
# Nothing else maps. Sets G_ROOT/G_REL/G_ABS; returns 1 to skip.
global_target() {  # <payload_rel>
  local rel="$1"
  case "$rel" in
    .opencode/agent/*)         G_ROOT="$OPENCODE_AGENT_DIR"; G_REL="${rel##*/}" ;;
    .claude/commands/collab/*) G_ROOT="$CLAUDE_DIR";         G_REL="commands/collab/${rel##*/}" ;;
    collab/*)                  G_ROOT="$CLAUDE_DIR";         G_REL="$rel" ;;
    *) return 1 ;;
  esac
  G_ABS="$G_ROOT/$G_REL"
  return 0
}

# Last-match-wins hash lookup for an absolute path in a hashes file. Last wins so an
# upgraded file's fresh record (appended after the old one during a run) is the one
# uninstall trusts — the mid-run durability guarantee below depends on it.
g_hash_of() {  # <hashesfile> <abspath>
  local f="$1" p="$2" found
  [ -f "$f" ] || return 1
  found="$(awk -F '\t' -v p="$p" '$2==p && NF==2 {h=$1} END{if(h!=""){print h}else{exit 1}}' "$f")" || return 1
  valid_hash "$found" || return 1
  printf '%s\n' "$found"
}

# A path is ours only while its current bytes match the record from BEFORE this run
# (frozen in $gh_old). No legacy-format migration: the global layout is new, so there
# are no path-only global manifests to adopt.
g_is_owned() {  # <abspath>
  local abs="$1" expected actual
  expected="$(g_hash_of "$gh_old" "$abs" 2>/dev/null || true)"
  [ -f "$abs" ] && [ ! -L "$abs" ] || return 1
  actual="$(sha256_file "$abs")"
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

# Update the accumulators: replace any prior record for <abs> with <hash>, and index
# the path. The accumulators are SEEDED from the prior on-disk records, so a file we
# skip this run keeps its old record (parity with copy_one's retain behaviour) and a
# file we don't re-process keeps its record too — which is what makes a mid-run flush
# leave an accurate, complete ownership set for uninstall.
g_set_record() {  # <abspath> <hash>
  local abs="$1" hash="$2" t
  t="$(mktemp)" || die "could not create a temporary file"
  awk -F '\t' -v p="$abs" '$2!=p' "$gh_new" > "$t" && mv -f "$t" "$gh_new"
  printf '%s\t%s\n' "$hash" "$abs" >> "$gh_new"
  grep -qxF "$abs" "$gm_new" 2>/dev/null || printf '%s\n' "$abs" >> "$gm_new"
}

# Atomically replace the on-disk global manifest/hashes from the accumulators, via
# mktemp+mv so a hardlinked reserved path cannot be written THROUGH to an outside
# inode (the same defence the per-project metadata writes use). Called after EVERY
# file, so a mid-run failure still leaves records matching exactly what is on disk.
g_flush() {
  local t
  safe_under_root "$CLAUDE_DIR" "collab/.install-manifest.global"
  safe_under_root "$CLAUDE_DIR" "collab/.install-hashes.global"
  t="$(mktemp "$CLAUDE_DIR/collab/.cc-gman.XXXXXX")" || die "could not create a secure manifest temporary file"
  sort -u "$gm_new" > "$t" && mv -f "$t" "$GMANIFEST" || { rm -f "$t"; die "could not write global manifest"; }
  t="$(mktemp "$CLAUDE_DIR/collab/.cc-ghash.XXXXXX")" || die "could not create a secure hashes temporary file"
  sort -u "$gh_new" > "$t" && mv -f "$t" "$GHASHES" || { rm -f "$t"; die "could not write global hashes"; }
}

g_copy_one() {  # <payload_rel>
  local rel="$1" abs root relu tmp c
  global_target "$rel" || return 0        # nothing else maps
  root="$G_ROOT"; relu="$G_REL"; abs="$G_ABS"
  safe_under_root "$root" "$relu"
  if [ -e "$abs" ] && ! g_is_owned "$abs"; then
    warn "skipping $abs — a file you already have is there; leaving it untouched"
    printf '%s\n' "$abs" >> "$skipped_list"
    skipped=$((skipped+1)); return
  fi
  mkdir -p "$(dirname "$abs")"
  tmp="$(mktemp "$(dirname "$abs")/.cc-payload.XXXXXX")" || die "could not create a secure payload temporary file"
  case "$rel" in
    .claude/commands/collab/*)
      # A slash command hardcodes `bash collab/…` in its body AND in every
      # allowed-tools grant variant (env-prefixed, COLLAB_CONFIRMED=1/RUN_ID forms,
      # the `RUN=$(bash collab/log.sh new-run:*)` command-substitution grant, and the
      # `… | bash collab/log.sh …` pipe). Globally the scripts live at an absolute
      # path, so rewrite the single common literal prefix `bash collab/` → `bash
      # <CLAUDE_DIR>/collab/`. That one substitution covers every form uniformly and
      # leaves bare prose paths (e.g. `collab/models.policy.local`, which the scripts
      # resolve relative to themselves) untouched. Done with bash literal parameter
      # expansion, NOT sed/awk: the replacement contains `<CLAUDE_DIR>`, which may hold
      # `&`, `\`, `/` that sed/gsub would reinterpret — the same escape-class bug as the
      # awk -v fix. The `cat; printf x` / `%x` guard preserves trailing newlines that a
      # bare `$(...)` capture would strip (this repo has been burned by that before).
      c="$(cat "$src/$rel"; printf x)" || { rm -f "$tmp"; die "could not read command file: $rel"; }
      c="${c%x}"
      c="${c//bash collab\//bash $CLAUDE_DIR/collab/}"
      printf '%s' "$c" > "$tmp" || { rm -f "$tmp"; die "could not template command file: $rel"; }
      chmod 0644 "$tmp"
      ;;
    *)
      cp -p "$src/$rel" "$tmp" || { rm -f "$tmp"; die "could not prepare payload file: $rel"; }
      case "$relu" in collab/*.sh|collab/tests/fake-opencode) chmod +x "$tmp" ;; esac
      ;;
  esac
  mv -f "$tmp" "$abs"
  g_set_record "$abs" "$(sha256_file "$abs")"   # hash of the TEMPLATED bytes on disk
  g_flush
  count=$((count+1))
}

# Merge (never clobber) the two knobs the installed scripts need to run in global
# mode into CLAUDE_DIR/collab/collab.conf.local: COLLAB_AGENT_DIR (so the wrapper's
# fallback check probes the SAME dir opencode resolves --agent from) and
# COLLAB_LOG_PARTITION=1 (so each project's logs/`latest`/witness stay separate under
# the one shared log root). Every pre-existing line — the user's COLLAB_MODEL etc. —
# is preserved verbatim. Key detection matches conf_get's parser (leading whitespace
# trimmed, `#` comments ignored). The two keys differ in update policy:
#   - COLLAB_AGENT_DIR is UPDATE-ALWAYS: the installer owns this path (it's derived
#     from the resolved opencode dir and must track it), so a prior line is replaced.
#   - COLLAB_LOG_PARTITION is SET-IF-ABSENT: if the user already set it (even to 0),
#     their line is preserved verbatim — we never silently override a deliberate
#     config choice. It is only added (=1) when the key is absent.
# The agent dir is passed through ENVIRON, NOT `awk -v`: -v runs the value through
# awk's backslash-escape processing, which would corrupt a path containing a '\'
# (e.g. an XDG dir with a backslash) and make the merge branch disagree with the
# escape-free printf fresh branch below — a re-install would then rewrite a correct
# value to a wrong one. ENVIRON delivers the bytes verbatim, matching the fresh path.
g_write_conf() {
  local conf="$CLAUDE_DIR/collab/collab.conf.local" tmp
  safe_under_root "$CLAUDE_DIR" "collab/collab.conf.local"
  if [ -e "$conf" ] && { [ ! -f "$conf" ] || [ -L "$conf" ]; }; then
    die "refusing non-file collab.conf.local path: $conf"
  fi
  mkdir -p "$CLAUDE_DIR/collab"
  tmp="$(mktemp "$CLAUDE_DIR/collab/.cc-conf.XXXXXX")" || die "could not create a secure conf temporary file"
  if [ -f "$conf" ]; then
    cc_adir="$OPENCODE_AGENT_DIR" awk '
      function keyof(l,  s,eq,k){ s=l; sub(/^[[:space:]]+/,"",s)
        if(s ~ /^#/ || s !~ /=/) return ""
        eq=index(s,"="); k=substr(s,1,eq-1); gsub(/[[:space:]]/,"",k); return k }
      { k=keyof($0)
        if(k=="COLLAB_AGENT_DIR"){ if(!sa){print "COLLAB_AGENT_DIR=" ENVIRON["cc_adir"]; sa=1} next }
        if(k=="COLLAB_LOG_PARTITION"){ sp=1; print; next }
        print }
      END{ if(!sa) print "COLLAB_AGENT_DIR=" ENVIRON["cc_adir"]
           if(!sp) print "COLLAB_LOG_PARTITION=1" }
    ' "$conf" > "$tmp" || { rm -f "$tmp"; die "could not rewrite collab.conf.local"; }
  else
    {
      printf '# collab.conf.local — written by install.sh --global (global/user-level layout).\n'
      printf '# COLLAB_AGENT_DIR points the wrapper fallback check at the opencode global agent dir.\n'
      printf '# COLLAB_LOG_PARTITION=1 keeps each project'\''s logs separate under the shared log root.\n'
      printf 'COLLAB_AGENT_DIR=%s\n' "$OPENCODE_AGENT_DIR"
      printf 'COLLAB_LOG_PARTITION=1\n'
    } > "$tmp" || { rm -f "$tmp"; die "could not write collab.conf.local"; }
  fi
  mv -f "$tmp" "$conf"
}

global_install() {
  g_resolve_roots create
  # A global command file bakes the resolved CLAUDE_DIR into its body and every
  # allowed-tools grant as an UNQUOTED shell token (`bash <dir>/collab/ask.sh …`), so a
  # whitespace-bearing path (a $HOME with a space) would word-split at runtime and break
  # every command silently. Fail closed with an actionable message instead — this is the
  # INSTALL path only; global_uninstall must never refuse, so it can always clean up.
  case "$CLAUDE_DIR$OPENCODE_AGENT_DIR" in
    *[[:space:]]*)
      die "--global cannot bake a path containing whitespace into command invocations (resolved: '$CLAUDE_DIR', '$OPENCODE_AGENT_DIR'). Use the per-project install (bash install.sh --dest <project>), or a home path without spaces." ;;
  esac
  if [ "$src" -ef "$CLAUDE_DIR" ] 2>/dev/null; then
    die "Payload source is your Claude config dir itself — run --global from a clone or via curl … | bash."
  fi
  GMANIFEST="$CLAUDE_DIR/collab/.install-manifest.global"
  GHASHES="$CLAUDE_DIR/collab/.install-hashes.global"
  mkdir -p "$CLAUDE_DIR/collab"
  safe_under_root "$CLAUDE_DIR" "collab/.install-manifest.global"
  safe_under_root "$CLAUDE_DIR" "collab/.install-hashes.global"
  { [ -e "$GMANIFEST" ] && [ ! -f "$GMANIFEST" ]; } && die "refusing non-file global manifest path: $GMANIFEST"
  { [ -e "$GHASHES" ] && [ ! -f "$GHASHES" ]; } && die "refusing non-file global hashes path: $GHASHES"

  say "Installing ClaudeCollab (global / user-level)"
  say "  from:         $src"
  say "  scripts   ->  $CLAUDE_DIR/collab/"
  say "  commands  ->  $CLAUDE_DIR/commands/collab/  (invocations rewritten to absolute)"
  say "  agent defs -> $OPENCODE_AGENT_DIR/"

  gh_old="$(mktemp)"; gm_new="$(mktemp)"; gh_new="$(mktemp)"; skipped_list="$(mktemp)"
  [ -f "$GHASHES" ] && cp "$GHASHES" "$gh_old"
  [ -f "$GHASHES" ] && cp "$GHASHES" "$gh_new"
  [ -f "$GMANIFEST" ] && cp "$GMANIFEST" "$gm_new"
  count=0; skipped=0
  g_flush                                  # persist seeded state before any copy
  while IFS= read -r rel; do
    g_copy_one "$rel"
  done < <(payload_files)
  g_flush
  g_write_conf

  ok "Installed ${count} file(s)$( [ "$skipped" -gt 0 ] && printf ', skipped %d already-present file(s)' "$skipped")."
  if [ "$skipped" -gt 0 ]; then
    warn "These ClaudeCollab files were NOT installed because you already had a file at that path:"
    while IFS= read -r p; do warn "    $p"; done < "$skipped_list"
    warn "Your files were left untouched; the ClaudeCollab version of each is absent."
  fi
  say "Wrote $CLAUDE_DIR/collab/collab.conf.local (COLLAB_AGENT_DIR, COLLAB_LOG_PARTITION)."
  say "Next steps:"
  say "  1. Authenticate opencode:  opencode auth login"
  say "  2. Check the setup:        bash $CLAUDE_DIR/collab/doctor.sh"
}

g_root_rel() {  # <abspath> -> sets G_UROOT/G_UREL; returns 1 if under neither root
  local abs="$1"
  case "$abs" in
    "$CLAUDE_DIR"/*)         G_UROOT="$CLAUDE_DIR";         G_UREL="${abs#"$CLAUDE_DIR"/}" ;;
    "$OPENCODE_AGENT_DIR"/*) G_UROOT="$OPENCODE_AGENT_DIR"; G_UREL="${abs#"$OPENCODE_AGENT_DIR"/}" ;;
    *) return 1 ;;
  esac
  return 0
}

g_remove_if_owned() {  # <abspath>
  local abs="$1" expected actual
  if ! g_root_rel "$abs"; then
    warn "keeping path outside the current global roots (config drift?): $abs"; return 0
  fi
  safe_under_root "$G_UROOT" "$G_UREL"
  [ -e "$abs" ] || return 0
  if [ ! -f "$abs" ] || [ -L "$abs" ]; then
    warn "keeping changed/non-file path: $abs"; return 0
  fi
  expected="$(g_hash_of "$GHASHES" "$abs" 2>/dev/null || true)"
  actual="$(sha256_file "$abs")"
  if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
    rm -f "$abs"; removed=$((removed+1))
  else
    warn "keeping changed or unverified file: $abs"
  fi
}

global_uninstall() {
  g_resolve_roots nocreate
  GMANIFEST="$CLAUDE_DIR/collab/.install-manifest.global"
  GHASHES="$CLAUDE_DIR/collab/.install-hashes.global"
  say "Uninstalling ClaudeCollab (global / user-level) from:"
  say "  $CLAUDE_DIR/collab/  and  $OPENCODE_AGENT_DIR/"
  if [ ! -f "$GMANIFEST" ] && [ ! -f "$GHASHES" ]; then
    warn "no global install records under $CLAUDE_DIR/collab — nothing to remove."
    return 0
  fi
  if [ -e "$GMANIFEST" ] && [ ! -f "$GMANIFEST" ]; then die "refusing non-file global manifest path: $GMANIFEST"; fi
  if [ -e "$GHASHES" ] && [ ! -f "$GHASHES" ]; then die "refusing non-file global hashes path: $GHASHES"; fi
  removed=0
  # Prefer the manifest's path index; fall back to the hashes' path field if lost.
  local list; list="$(mktemp)"
  if [ -f "$GMANIFEST" ]; then
    cp "$GMANIFEST" "$list"
  else
    awk -F '\t' 'NF==2 {print $2}' "$GHASHES" | sort -u > "$list"
  fi
  while IFS= read -r abs || [ -n "$abs" ]; do
    [ -n "$abs" ] || continue
    case "$abs" in /*) ;; *) warn "skipping suspicious non-absolute record: $abs"; continue ;; esac
    g_remove_if_owned "$abs"
  done < "$list"
  rm -f "$list"
  rm -f "$GMANIFEST" "$GHASHES"
  # rmdir only-empty payload dirs, deepest first. collab/collab.conf.local and any
  # collab/logs/ runs keep their parent dirs alive — user config and audit logs are
  # deliberately NOT removed by an uninstall. commands/collab + commands are pruned
  # only if empty, so a user's OTHER slash commands keep commands/ alive. The opencode
  # agent dir (and its parent `opencode` dir) are pruned only if empty, so a user's
  # other opencode config is safe.
  local d
  for d in "$CLAUDE_DIR/collab/tests" "$CLAUDE_DIR/collab/logs" "$CLAUDE_DIR/collab" \
           "$CLAUDE_DIR/commands/collab" "$CLAUDE_DIR/commands" \
           "$OPENCODE_AGENT_DIR" "$(dirname "$OPENCODE_AGENT_DIR")"; do
    [ -d "$d" ] && rmdir "$d" 2>/dev/null || true
  done
  ok "Removed ClaudeCollab global install (${removed} file(s)). Your config and logs were left untouched."
}

# =============================== UNINSTALL ====================================
if [ "$action" = "uninstall" ]; then
  if [ -n "$global" ]; then global_uninstall; exit 0; fi
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
# A ref reaches `git clone --branch`, so keep it to plain ref characters and
# never let it open with '-' (which git would read as an option, not a value).
valid_ref() {
  case "$1" in
    -*|*[!A-Za-z0-9._/-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# The latest release tag, or empty if the repo has none. git does the version
# sort itself (--sort=-v:refname) so this needs no GitHub API, no auth beyond
# repo access, and no `sort -V` — which is a GNU extension that stock macOS
# `sort` lacks. awk drains the whole list rather than `head -1` closing the
# pipe, which under `set -o pipefail` would surface as a SIGPIPE failure.
latest_release_tag() {
  git ls-remote --tags --refs --sort=-v:refname "$REPO_URL" 'v*' 2>/dev/null \
    | awk -F'refs/tags/' 'NR==1 && NF>1 {t=$2} END {if (t != "") print t}'
}

# Locate the payload. An explicit --ref always fetches: the user named a version,
# so honour it over whatever this clone happens to be sitting on. Otherwise a
# clone supplies its own payload as-is, and only the piped path fetches — at the
# latest release, since curl|bash should give a release, not development tip.
src="$self_dir"
tmp_src=""
if [ -n "$REF" ] || ! have_payload "$src"; then
  command -v git >/dev/null 2>&1 || die "git is required to fetch ClaudeCollab. Install git, or run from a clone."
  if [ -n "$REF" ]; then
    valid_ref "$REF" || die "refusing unsafe ref: $REF"
  else
    REF="$(latest_release_tag)" || REF=""
    if [ -n "$REF" ]; then
      say "Latest release: $REF"
    else
      say "No release tags found — falling back to the default branch."
    fi
  fi
  tmp_src="$(mktemp -d)"
  say "Fetching ClaudeCollab from $REPO_URL${REF:+ at $REF}"
  clone_args=(--depth 1)
  if [ -n "$REF" ]; then clone_args+=(--branch "$REF"); fi
  git clone "${clone_args[@]}" "$REPO_URL" "$tmp_src" >/dev/null 2>&1 \
    || die "git clone failed: $REPO_URL${REF:+ at ref '$REF'}"
  src="$tmp_src"
fi
cleanup() {
  [ -n "$tmp_src" ] && rm -rf "$tmp_src"
  [ -n "${skipped_list:-}" ] && rm -f "$skipped_list"
  [ -n "${manifest_tmp:-}" ] && rm -f "$manifest_tmp"
  [ -n "${hashes_tmp:-}" ] && rm -f "$hashes_tmp"
  [ -n "${gh_old:-}" ] && rm -f "$gh_old"
  [ -n "${gm_new:-}" ] && rm -f "$gm_new"
  [ -n "${gh_new:-}" ] && rm -f "$gh_new"
  return 0
}
trap cleanup EXIT

# --global install: a separate branch that never touches $dest or the per-project
# ownership/gitignore machinery. It needs $src (the resolved payload), which the block
# above supplied, so it dispatches here — before the per-project source==dest guard,
# whose $dest=$PWD would wrongly fire when --global is run from inside a clone.
if [ -n "$global" ]; then global_install; exit 0; fi

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
