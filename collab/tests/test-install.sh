#!/usr/bin/env bash
# test-install.sh — smoke tests for the repo-root install.sh.
# Token-free and opencode-free: installs into throwaway temp dirs and asserts the
# file/gitignore/manifest behaviour, idempotency, the merge-not-clobber guarantee
# (both the happy path and the dangerous same-path / pre-existing-collab cases),
# the gitignore missing-end-marker guard, the no-manifest fallback, and the
# source==dest guard. No model is called.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
installer="$repo_root/install.sh"
pass=0; fail=0
ok()  { printf '\033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
no()  { printf '\033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else no "$1 -- ($2)"; fi; }
newrepo(){ local d; d="$(mktemp -d)"; ( cd "$d" && git init -q ) 2>/dev/null; printf '%s' "$d"; }

[ -f "$installer" ] || { echo "install.sh not found at $installer" >&2; exit 1; }

# --- fresh install -----------------------------------------------------------
T="$(newrepo)"
bash "$installer" --dest "$T" >/dev/null 2>&1
check "installs ask.sh"                 "[ -f '$T/collab/ask.sh' ]"
check "ask.sh is executable"            "[ -x '$T/collab/ask.sh' ]"
check "fake-opencode is executable"     "[ -x '$T/collab/tests/fake-opencode' ]"
check "installs a slash command"        "[ -f '$T/.claude/commands/collab/consult.md' ]"
check "installs an agent def"           "[ -f '$T/.opencode/agent/collab-read.md' ]"
check "writes an install manifest"      "[ -f '$T/collab/.install-manifest' ]"
check "gitignore has our block"         "grep -q 'ClaudeCollab >>>' '$T/.gitignore'"
check "gitignore ignores conf.local"    "grep -q 'collab/collab.conf.local' '$T/.gitignore'"

# --- idempotent re-install (gitignore block must not duplicate) --------------
bash "$installer" --dest "$T" >/dev/null 2>&1
n=$(grep -c 'ClaudeCollab >>>' "$T/.gitignore")
check "re-install keeps one gitignore block" "[ '$n' -eq 1 ]"

# --- uninstall removes exactly ours ------------------------------------------
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "uninstall removes collab/"       "[ ! -d '$T/collab' ]"
check "uninstall removes commands"      "[ ! -f '$T/.claude/commands/collab/consult.md' ]"
check "uninstall removes agent defs"    "[ ! -f '$T/.opencode/agent/collab-read.md' ]"
check "uninstall drops gitignore block" "! grep -q 'ClaudeCollab' '$T/.gitignore' 2>/dev/null"
rm -rf "$T"

# --- merge-not-clobber: user's DIFFERENT-named files survive uninstall -------
T="$(newrepo)"
mkdir -p "$T/.claude/commands" "$T/.opencode/agent"
echo "mine" > "$T/.claude/commands/mycmd.md"
echo "mine" > "$T/.opencode/agent/myagent.md"
printf 'node_modules/\n*.log\n' > "$T/.gitignore"
bash "$installer" --dest "$T" >/dev/null 2>&1
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "keeps user's command"            "[ -f '$T/.claude/commands/mycmd.md' ]"
check "keeps user's agent def"          "[ -f '$T/.opencode/agent/myagent.md' ]"
check "keeps user's gitignore lines"    "grep -q 'node_modules/' '$T/.gitignore'"
rm -rf "$T"

# --- SAME-PATH conflict: a user file at our exact path is never clobbered -----
T="$(newrepo)"
mkdir -p "$T/.claude/commands/collab"
echo "USER-OWNED consult" > "$T/.claude/commands/collab/consult.md"
bash "$installer" --dest "$T" >/dev/null 2>&1
check "install does NOT overwrite user's same-name file" "grep -q 'USER-OWNED' '$T/.claude/commands/collab/consult.md'"
check "skipped file is not in the manifest"              "! grep -qx '.claude/commands/collab/consult.md' '$T/collab/.install-manifest'"
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "uninstall does NOT delete user's same-name file"  "[ -f '$T/.claude/commands/collab/consult.md' ] && grep -q 'USER-OWNED' '$T/.claude/commands/collab/consult.md'"
rm -rf "$T"

# --- a skipped file must stay VISIBLE, at install time and afterwards ---------
# Keeping the user's file is deliberate; leaving them unaware that OUR version is
# therefore absent is not. The command still exists, so nothing looks broken —
# it just isn't ours. Both signals below are the only thing standing between the
# user and a silently shadowed command.
T="$(newrepo)"
mkdir -p "$T/.claude/commands/collab"
echo "USER-OWNED consult" > "$T/.claude/commands/collab/consult.md"
# Capture to FILES, not variables: `check` eval's its argument, so interpolating
# multi-line output into the string breaks the eval and the case fails for reasons
# that have nothing to do with the behaviour under test.
outf="$T/.install-out.txt"; docf="$T/.doctor-out.txt"
bash "$installer" --dest "$T" > "$outf" 2>&1
check "install SUMMARISES the skip by name at the end (not just an inline warning)" \
  "grep -q 'were NOT installed' '$outf' && grep -q 'commands/collab/consult.md' '$outf'"
( cd "$T" && bash collab/doctor.sh > "$docf" 2>&1 )
check "doctor reports the shadowed command afterwards"  "grep -q 'did NOT install' '$docf'"
check "doctor does NOT claim all commands are ours"     "! grep -q 'present and ours' '$docf'"
rm -rf "$T"

# --- pre-existing collab/ contents survive uninstall (no rm -rf) --------------
T="$(newrepo)"
mkdir -p "$T/collab"
echo "my own tool" > "$T/collab/mine.sh"
bash "$installer" --dest "$T" >/dev/null 2>&1
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "user's file under collab/ survives uninstall" "[ -f '$T/collab/mine.sh' ]"
check "collab/ dir survives when user has files in it" "[ -d '$T/collab' ]"
rm -rf "$T"

# --- gitignore with a lone BEGIN marker is not truncated ----------------------
T="$(newrepo)"
printf '%s\n%s\n%s\n' '# >>> ClaudeCollab >>>' 'keep-me-line' 'node_modules/' > "$T/.gitignore"
bash "$installer" --dest "$T" >/dev/null 2>&1        # add_gitignore_block strips first
check "lone begin-marker does not eat the rest of .gitignore" "grep -q 'keep-me-line' '$T/.gitignore' && grep -q 'node_modules/' '$T/.gitignore'"
rm -rf "$T"

# --- no-manifest fallback still removes our files (derived from source) --------
T="$(newrepo)"
bash "$installer" --dest "$T" >/dev/null 2>&1
rm -f "$T/collab/.install-manifest"                  # simulate a lost/corrupt manifest
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "fallback uninstall removes collab/"  "[ ! -d '$T/collab' ]"
check "fallback uninstall removes commands" "[ ! -f '$T/.claude/commands/collab:panel.md' ]"
rm -rf "$T"

# --- dest path containing a space --------------------------------------------
base="$(mktemp -d)"; T="$base/with space"; mkdir -p "$T"; ( cd "$T" && git init -q ) 2>/dev/null
bash "$installer" --dest "$T" >/dev/null 2>&1
check "installs into a path with a space" "[ -f '$T/collab/ask.sh' ]"
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "uninstalls from a path with a space" "[ ! -d '$T/collab' ]"
rm -rf "$base"

# --- guard: refuse to install onto the source itself -------------------------
if bash "$installer" --dest "$repo_root" >/dev/null 2>&1; then
  no "source==dest guard should refuse (exit non-zero)"
else
  ok "refuses to install onto the ClaudeCollab source"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
