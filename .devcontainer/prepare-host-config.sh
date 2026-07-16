#!/usr/bin/env bash
# Stage only selected host Claude config paths for the devcontainer.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
stage="${CLAUDECOLLAB_HOST_CONFIG_STAGE:-$repo_root/.devcontainer/.host-config}"
source_dir="${HOME}/.claude"

[ -d "$source_dir" ] || exit 0
source_dir="$(cd "$source_dir" && pwd -P)"

die() { printf 'prepare-host-config.sh: %s\n' "$*" >&2; exit 1; }

# Resolve an existing path without relying on GNU realpath. Final-component
# symlinks are followed explicitly; cd -P resolves symlinks in parent paths.
resolve_existing() {
  local path="$1" target hops=0 parent
  while [ -L "$path" ]; do
    hops=$((hops+1)); [ "$hops" -le 40 ] || return 1
    target="$(readlink "$path")" || return 1
    case "$target" in
      /*) path="$target" ;;
      *) path="$(dirname "$path")/$target" ;;
    esac
  done
  if [ -d "$path" ]; then
    (cd "$path" && pwd -P)
  elif [ -e "$path" ]; then
    parent="$(cd "$(dirname "$path")" && pwd -P)" || return 1
    printf '%s/%s\n' "$parent" "$(basename "$path")"
  else
    return 1
  fi
}

validate_link() {
  local link="$1" resolved
  case "$link" in *$'\n'*) die "refusing symlink with a newline in its path" ;; esac
  resolved="$(resolve_existing "$link")" || die "refusing dangling or unresolvable symlink: $link"
  case "$resolved" in
    "$source_dir"|"$source_dir"/*) ;;
    *) die "refusing symlink outside $source_dir: $link -> $resolved" ;;
  esac
  printf '%s\n' "$resolved"
}

# Validate every reachable entry before clearing the prior snapshot. Internal
# directory links can lead elsewhere in ~/.claude, so inspect their targets too.
scanned_dirs=()
active_dirs=()
scan_tree() {
  local root="$1" path resolved seen active_index
  resolved="$(resolve_existing "$root")" || die "cannot resolve selected directory: $root"
  [ -d "$resolved" ] || die "selected directory is not a directory: $root"
  # `${arr[@]+"${arr[@]}"}` — NOT plain `"${arr[@]}"`. Both arrays are empty on the
  # first scan_tree call, and under `set -u` bash 3.2 (stock macOS) calls an empty
  # array's [@] expansion an unbound variable and aborts. bash >= 4.4 does not, so
  # Linux never sees it: this aborted host-config staging on macOS outright, caught
  # by the macOS CI job on its first run.
  for seen in ${active_dirs[@]+"${active_dirs[@]}"}; do
    [ "$seen" = "$resolved" ] && die "refusing cyclic internal directory symlink: $root -> $resolved"
  done
  for seen in ${scanned_dirs[@]+"${scanned_dirs[@]}"}; do
    [ "$seen" = "$resolved" ] && return 0
  done
  scanned_dirs+=("$resolved")
  active_dirs+=("$resolved")
  while IFS= read -r -d '' path; do
    if [ -L "$path" ]; then
      resolved="$(validate_link "$path")"
      if [ -d "$resolved" ]; then
        scan_tree "$resolved"
      elif [ ! -f "$resolved" ]; then
        die "refusing non-regular symlink target: $path -> $resolved"
      fi
    elif [ ! -d "$path" ] && [ ! -f "$path" ]; then
      die "refusing non-regular config entry: $path"
    fi
  done < <(find "$resolved" -mindepth 1 -print0)
  active_index=$((${#active_dirs[@]} - 1))
  unset "active_dirs[$active_index]"
}

# The selected top-level files are named by this script, so their targets are not
# a surprise: a dotfiles-managed ~/.claude symlinks them out to the dotfiles tree,
# and confining them to $source_dir aborted startup for that whole setup. cp -L
# stages a real copy either way. validate_link still guards the symlinks scan_tree
# *discovers*, which are the ones that could pull in something unintended.
preflight_file() {
  local path="$1" resolved
  [ -e "$path" ] || [ -L "$path" ] || return 0
  resolved="$(resolve_existing "$path")" || die "refusing dangling or unresolvable symlink: $path"
  [ -f "$resolved" ] || die "selected config file is not regular: $path"
}

preflight_dir() {
  local path="$1" resolved
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if [ -L "$path" ]; then
    resolved="$(validate_link "$path")"
  else
    resolved="$path"
  fi
  [ -d "$resolved" ] || die "selected config directory is not a directory: $path"
  scan_tree "$resolved"
}

for file in CLAUDE.md settings.json statusline-command.sh; do
  preflight_file "$source_dir/$file"
done
for dir in commands agents; do
  preflight_dir "$source_dir/$dir"
done

rm -rf "$stage"
mkdir -p "$stage"

for file in CLAUDE.md settings.json statusline-command.sh; do
  if [ -e "$source_dir/$file" ]; then cp -L "$source_dir/$file" "$stage/$file"; fi
done

for dir in commands agents; do
  if [ -d "$source_dir/$dir" ]; then cp -RL "$source_dir/$dir" "$stage/$dir"; fi
done
