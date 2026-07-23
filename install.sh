#!/usr/bin/env bash
# install.sh — thin bootstrap for ModelGuild (TypeScript / MCP era).
#
# ModelGuild is distributed as an npm package (`modelguild`) whose `init`
# command places the payload into a project:
#   .claude/commands/guild/  the slash commands (/guild:consult, /guild:panel, …)
#   .opencode/agent/          the hardened guild-read / guild-build / guild-research defs
#   modelguild/                   the model policy + config template
# MCP registration is user-driven: `init` does NOT write .mcp.json by default. It prints
# the `claude mcp add modelguild -s <scope> -- …` command for you to run (your choice of
# global/project/local scope). The opt-in `--write-mcp` flag restores the old behavior of
# merging a project-scoped `.mcp.json` entry for the `modelguild` MCP server.
#
# THIS SCRIPT IS ONLY A CONVENIENCE. It exists so the classic one-liner still works:
#   curl -fsSL https://raw.githubusercontent.com/bencmorrison/modelguild/main/install.sh | bash
# All it does is make the npm package available and run `modelguild init` in your
# project. The real installer — including the SHA-256 ownership model that upgrades/
# removes only files it wrote, the optional --write-mcp .mcp.json merge, and the shadow-detection warnings —
# lives inside the package (`modelguild init`, src/init.ts). This script reimplements
# none of that; it just delegates.
#
# The equivalent without this script (and the primary documented path) is simply:
#   npx modelguild init                 # in your project
#   npx modelguild init --uninstall     # to remove it
#
# Usage:
#   bash install.sh [--dir <dir>]        install into <dir> (default: current dir)
#   bash install.sh --uninstall [--dir <dir>]   remove it again (hash-verified)
#   bash install.sh --ref <version>      install a specific npm version/dist-tag
#   bash install.sh --global             `npm i -g` the CLI first, then init (a global
#                                        `modelguild` on PATH), instead of npx-on-demand
#   bash install.sh --help
#
#   Any further arguments after `--` are passed through to `modelguild init`.
#   Override the package with MODELGUILD_PKG=<name-or-tarball-or-git-url>.
#   Pin the version with MODELGUILD_REF=<version> (same as --ref).
set -euo pipefail

PKG="${MODELGUILD_PKG:-modelguild}"
REF="${MODELGUILD_REF:-latest}"
dir="$PWD"
uninstall=""
global_cli=""
passthrough=()

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) uninstall=1 ;;
    --global) global_cli=1 ;;
    --dir|--dest) shift; dir="${1:?--dir needs a directory}" ;;
    --dir=*) dir="${1#--dir=}" ;;
    --dest=*) dir="${1#--dest=}" ;;
    --ref) shift; REF="${1:?--ref needs a version or dist-tag}" ;;
    --ref=*) REF="${1#--ref=}" ;;
    --) shift; while [ $# -gt 0 ]; do passthrough+=("$1"); shift; done; break ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
  shift
done

command -v node >/dev/null 2>&1 || die "Node.js is required (https://nodejs.org). ModelGuild ships as an npm package."
command -v npm  >/dev/null 2>&1 || die "npm is required (it ships with Node.js)."

# A leading 'v' is a git-tag habit, not an npm version — strip it so `--ref v1.0.0`
# resolves the published 1.0.0, while dist-tags (latest, next) and ranges pass through.
case "$REF" in v[0-9]*) REF="${REF#v}" ;; esac
spec="${PKG}@${REF}"

# The command that provides `modelguild`: a global install (persists on PATH), or
# npx-on-demand (no global footprint — the documented default).
if [ -n "$global_cli" ]; then
  printf 'install.sh: installing the CLI globally (npm i -g %s)\n' "$spec" >&2
  npm install -g "$spec" || die "global install failed: npm i -g $spec"
  runner=(modelguild)
else
  runner=(npx -y "$spec")
fi

init_args=(init --dir "$dir")
[ -n "$uninstall" ] && init_args=(init --uninstall --dir "$dir")
init_args+=(${passthrough[@]+"${passthrough[@]}"})

printf 'install.sh: %s %s\n' "$(basename "${runner[0]}")" "${init_args[*]}" >&2
exec "${runner[@]}" "${init_args[@]}"
