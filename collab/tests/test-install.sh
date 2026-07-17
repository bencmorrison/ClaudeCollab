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
# macOS `mktemp -d` returns a path under /var/folders, and /var is an OS-level
# symlink to /private/var (as /tmp is to /private/tmp). install.sh refuses any
# destination with a symlink path component, so a raw temp path is unusable as a
# --dest there and every case cascades from one refusal. Canonicalize: this suite
# tests install behaviour, not the platform's temp-dir layout. The symlink-guard
# case below plants its own symlink and is unaffected.
mktempd(){ local d; d="$(mktemp -d)" || return 1; ( cd "$d" && pwd -P ); }
newrepo(){ local d; d="$(mktempd)"; ( cd "$d" && git init -q ) 2>/dev/null; printf '%s' "$d"; }
sha256(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1; else shasum -a 256 "$1" | cut -d ' ' -f 1; fi; }

# --- global-mode sandbox helpers ---------------------------------------------
# EVERY --global invocation is env-sandboxed onto a throwaway HOME/XDG so nothing
# can touch the real ~/.claude or ~/.config. real_marker() snapshots the real dirs;
# real_before/real_after bracket the global block and prove they were untouched.
REAL_HOME="${HOME:-}"
real_marker(){ { ls -1a "$REAL_HOME/.claude/collab" 2>/dev/null; ls -1a "${XDG_CONFIG_HOME:-$REAL_HOME/.config}/opencode/agent" 2>/dev/null; } | sort; }
gsandbox(){ local d; d="$(mktempd)"; mkdir -p "$d/.config"; printf '%s' "$d"; }
gi(){ local h="$1"; shift; HOME="$h" XDG_CONFIG_HOME="$h/.config" bash "$installer" --global "$@"; }  # gi <home> [args...]

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
check "writes ownership hashes"         "[ -f '$T/collab/.install-hashes' ]"
check "installs check-docs.sh"           "[ -f '$T/collab/tests/check-docs.sh' ]"
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

# --- unchanged owned files upgrade; locally changed files do not -------------
S="$(mktempd)"
cp -R "$repo_root/." "$S/"
T="$(newrepo)"
bash "$S/install.sh" --dest "$T" >/dev/null 2>&1
printf '\n# source upgrade\n' >> "$S/collab/ask.sh"
bash "$S/install.sh" --dest "$T" >/dev/null 2>&1
check "re-install upgrades an unchanged owned file" "grep -q 'source upgrade' '$T/collab/ask.sh'"
printf '\n# user replacement\n' >> "$T/collab/ask.sh"
printf '\n# second source upgrade\n' >> "$S/collab/ask.sh"
bash "$S/install.sh" --dest "$T" >/dev/null 2>&1
check "re-install preserves a changed owned-path file" "grep -q 'user replacement' '$T/collab/ask.sh' && ! grep -q 'second source upgrade' '$T/collab/ask.sh'"
bash "$S/install.sh" --uninstall --dest "$T" >/dev/null 2>&1
check "uninstall preserves a changed owned-path file" "grep -q 'user replacement' '$T/collab/ask.sh'"
rm -rf "$S" "$T"

# --- upgrades replace hardlinks instead of writing through outside dest -------
S="$(mktempd)"; cp -R "$repo_root/." "$S/"
T="$(newrepo)"; outside="$(mktempd)"
bash "$S/install.sh" --dest "$T" >/dev/null 2>&1
ln "$T/collab/ask.sh" "$outside/payload-canary"
printf 'OUTSIDE MANIFEST CANARY\n' >> "$T/collab/.install-manifest"
ln "$T/collab/.install-manifest" "$outside/manifest-canary"
cp "$outside/manifest-canary" "$outside/manifest-before"
printf 'invalid hash canary\n' >> "$T/collab/.install-hashes"
ln "$T/collab/.install-hashes" "$outside/hashes-canary"
cp "$outside/hashes-canary" "$outside/hashes-before"
ln "$T/collab/.install-state" "$outside/state-canary"
cp "$outside/state-canary" "$outside/state-before"
printf '\n# hardlink-safe source upgrade\n' >> "$S/collab/ask.sh"
bash "$S/install.sh" --dest "$T" >/dev/null 2>&1
check "hardlinked payload upgrade does not modify outside inode" "! grep -q 'hardlink-safe source upgrade' '$outside/payload-canary' && grep -q 'hardlink-safe source upgrade' '$T/collab/ask.sh'"
check "hardlinked manifest replacement does not modify outside inode" "cmp -s '$outside/manifest-before' '$outside/manifest-canary' && ! grep -q 'OUTSIDE MANIFEST CANARY' '$T/collab/.install-manifest'"
check "hardlinked hash replacement does not modify outside inode" "cmp -s '$outside/hashes-before' '$outside/hashes-canary' && ! grep -q 'invalid hash canary' '$T/collab/.install-hashes'"
check "hardlinked state replacement does not modify outside inode" "cmp -s '$outside/state-before' '$outside/state-canary' && [ ! '$T/collab/.install-state' -ef '$outside/state-canary' ]"
rm -rf "$S" "$T" "$outside"

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
# Match the slash-command line specifically: the agent-def check now emits "present
# and ours" too, so a bare grep for that phrase passes on the wrong line.
check "doctor does NOT claim all commands are ours"     "! grep -q 'slash commands present and ours' '$docf'"
rm -rf "$T"

# --- a shadowed AGENT def must be reported, not silently blessed --------------
# The agent names are distinctive so this is unlikely — but "unlikely" is not what a
# check is for, and doctor used to report "present" for a def that wasn't ours.
T="$(newrepo)"
mkdir -p "$T/.opencode/agent"
printf -- '---\ndescription: mine\nmode: all\npermission:\n  "*": allow\n---\nmine\n' > "$T/.opencode/agent/collab-read.md"
bash "$installer" --dest "$T" >/dev/null 2>&1
adocf="$T/.doctor-agents.txt"
( cd "$T" && bash collab/doctor.sh > "$adocf" 2>&1 )
check "doctor flags an agent def it did not install"   "grep -q 'did NOT install it' '$adocf'"
check "doctor does NOT call a shadowed agent def ours" "! grep -q 'collab-read agent def present and ours' '$adocf'"
check "install kept the user's agent def"              "grep -q 'mine' '$T/.opencode/agent/collab-read.md'"
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

# --- install chmod applies only to installed executable payload files ---------
T="$(newrepo)"
mkdir -p "$T/collab"
printf '#!/usr/bin/env bash\n' > "$T/collab/mine.sh"
chmod 0644 "$T/collab/mine.sh"
bash "$installer" --dest "$T" >/dev/null 2>&1
check "install does not chmod an unrelated user script" "[ ! -x '$T/collab/mine.sh' ]"
rm -rf "$T"

# --- gitignore with a lone BEGIN marker is not truncated ----------------------
T="$(newrepo)"
printf '%s\n%s\n%s\n' '# >>> ClaudeCollab >>>' 'keep-me-line' 'node_modules/' > "$T/.gitignore"
bash "$installer" --dest "$T" >/dev/null 2>&1        # add_gitignore_block strips first
check "lone begin-marker does not eat the rest of .gitignore" "grep -q 'keep-me-line' '$T/.gitignore' && grep -q 'node_modules/' '$T/.gitignore'"
rm -rf "$T"

# --- malformed/reversed/duplicate fences are left byte-for-byte intact --------
for variant in reversed duplicate_begin duplicate_end; do
  T="$(newrepo)"
  case "$variant" in
    reversed) printf '%s\n' '# <<< ClaudeCollab <<<' 'keep-a' '# >>> ClaudeCollab >>>' 'keep-b' > "$T/.gitignore" ;;
    duplicate_begin) printf '%s\n' '# >>> ClaudeCollab >>>' 'keep-a' '# >>> ClaudeCollab >>>' 'keep-b' '# <<< ClaudeCollab <<<' > "$T/.gitignore" ;;
    duplicate_end) printf '%s\n' '# >>> ClaudeCollab >>>' 'keep-a' '# <<< ClaudeCollab <<<' 'keep-b' '# <<< ClaudeCollab <<<' > "$T/.gitignore" ;;
  esac
  cp "$T/.gitignore" "$T/.gitignore.before"
  bash "$installer" --dest "$T" >/dev/null 2>&1
  check "$variant gitignore fences never truncate or rewrite content" "cmp -s '$T/.gitignore.before' '$T/.gitignore'"
  bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
  check "$variant gitignore fences survive uninstall intact" "cmp -s '$T/.gitignore.before' '$T/.gitignore'"
  rm -rf "$T"
done

# --- no-manifest fallback still removes our files (derived from source) --------
T="$(newrepo)"
bash "$installer" --dest "$T" >/dev/null 2>&1
rm -f "$T/collab/.install-manifest"                  # simulate a lost/corrupt manifest
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "fallback uninstall removes collab/"  "[ ! -d '$T/collab' ]"
check "fallback uninstall removes commands" "[ ! -f '$T/.claude/commands/collab/panel.md' ] && [ ! -f '$T/.claude/commands/collab/workshop.md' ]"
rm -rf "$T"

# --- missing-manifest fallback preserves replacements ------------------------
T="$(newrepo)"
bash "$installer" --dest "$T" >/dev/null 2>&1
rm -f "$T/collab/.install-manifest"
printf 'USER REPLACEMENT\n' > "$T/collab/ask.sh"
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "missing-manifest uninstall preserves replacement content" "grep -q 'USER REPLACEMENT' '$T/collab/ask.sh'"
rm -rf "$T"

# --- stale/forged path manifests are not ownership proof ---------------------
T="$(newrepo)"
mkdir -p "$T/collab"
printf 'USER FILE\n' > "$T/collab/ask.sh"
printf 'collab/ask.sh\n' > "$T/collab/.install-manifest"
printf '%064d\tcollab/ask.sh\n' 0 > "$T/collab/.install-hashes"
bash "$installer" --dest "$T" >/dev/null 2>&1
check "re-install ignores stale manifest ownership claims" "grep -q 'USER FILE' '$T/collab/ask.sh'"
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "uninstall ignores stale manifest ownership claims" "grep -q 'USER FILE' '$T/collab/ask.sh'"
rm -rf "$T"

# --- even a correct forged hash cannot authorize an arbitrary destination file
T="$(newrepo)"
bash "$installer" --dest "$T" >/dev/null 2>&1
printf 'IMPORTANT USER DATA\n' > "$T/important.txt"
forged_hash="$(sha256 "$T/important.txt")"
printf 'important.txt\n' >> "$T/collab/.install-manifest"
printf '%s\timportant.txt\n' "$forged_hash" >> "$T/collab/.install-hashes"
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "forged correct hash cannot delete a non-payload file" "grep -q 'IMPORTANT USER DATA' '$T/important.txt'"
rm -rf "$T"

# --- unrecognized user files at installer metadata paths are never clobbered --
for reserved in .install-manifest .install-hashes .install-state; do
  T="$(newrepo)"; mkdir -p "$T/collab"
  printf 'USER RESERVED METADATA\n' > "$T/collab/$reserved"
  cp "$T/collab/$reserved" "$T/reserved.before"
  if bash "$installer" --dest "$T" >/dev/null 2>&1; then
    no "install fails safely on user-owned collab/$reserved"
  else
    ok "install fails safely on user-owned collab/$reserved"
  fi
  check "install preserves user-owned collab/$reserved" "cmp -s '$T/reserved.before' '$T/collab/$reserved'"
  check "metadata conflict is detected before payload writes" "[ ! -e '$T/collab/ask.sh' ]"
  if bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1; then
    no "uninstall fails safely on user-owned collab/$reserved"
  else
    ok "uninstall fails safely on user-owned collab/$reserved"
  fi
  check "uninstall preserves user-owned collab/$reserved" "cmp -s '$T/reserved.before' '$T/collab/$reserved'"
  rm -rf "$T"
done

# --- each reserved metadata file must be independently recognizable -----------
for malformed in .install-manifest .install-hashes .install-state; do
  T="$(newrepo)"; mkdir -p "$T/collab"
  printf 'collab/ask.sh\n' > "$T/collab/.install-manifest"
  printf '%064d\tcollab/ask.sh\n' 0 > "$T/collab/.install-hashes"
  printf 'gitignore_preexisting=0\n' > "$T/collab/.install-state"
  printf 'USER RESERVED METADATA\n' > "$T/collab/$malformed"
  cp "$T/collab/$malformed" "$T/reserved.before"
  if bash "$installer" --dest "$T" >/dev/null 2>&1; then
    no "valid sibling metadata cannot authorize malformed collab/$malformed"
  else
    ok "valid sibling metadata cannot authorize malformed collab/$malformed"
  fi
  check "mixed-validity install preserves collab/$malformed" "cmp -s '$T/reserved.before' '$T/collab/$malformed'"
  check "mixed-validity conflict is detected before payload writes" "[ ! -e '$T/collab/doctor.sh' ]"
  if bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1; then
    no "mixed-validity uninstall rejects malformed collab/$malformed"
  else
    ok "mixed-validity uninstall rejects malformed collab/$malformed"
  fi
  check "mixed-validity uninstall preserves collab/$malformed" "cmp -s '$T/reserved.before' '$T/collab/$malformed'"
  rm -rf "$T"
done

# --- legacy path-only installs migrate only with byte-level proof -------------
T="$(newrepo)"
mkdir -p "$T/collab"
cp "$repo_root/collab/ask.sh" "$T/collab/ask.sh"
printf 'collab/ask.sh\n' > "$T/collab/.install-manifest"
bash "$installer" --dest "$T" >/dev/null 2>&1
check "matching legacy path-only file gains an ownership hash" "grep -q $'^[0-9a-f][0-9a-f]*\\tcollab/ask.sh$' '$T/collab/.install-hashes'"
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "migrated legacy install uninstalls cleanly" "[ ! -e '$T/collab/ask.sh' ]"
rm -rf "$T"

S="$(mktempd)"; cp -R "$repo_root/." "$S/"
T="$(newrepo)"; mkdir -p "$T/collab"
printf 'OLDER INSTALLED PAYLOAD\n' > "$T/collab/ask.sh"
printf 'collab/ask.sh\n' > "$T/collab/.install-manifest"
bash "$S/install.sh" --dest "$T" >/dev/null 2>&1
check "unverifiable legacy payload is not clobbered" "grep -q 'OLDER INSTALLED PAYLOAD' '$T/collab/ask.sh'"
check "unverifiable legacy ownership path is retained" "grep -qx 'collab/ask.sh' '$T/collab/.install-manifest'"
check "unverifiable legacy path is not assigned a fabricated hash" "! grep -q $'\\tcollab/ask.sh$' '$T/collab/.install-hashes'"
printf 'USER CHANGED LEGACY FILE\n' > "$T/collab/ask.sh"
bash "$S/install.sh" --dest "$T" >/dev/null 2>&1
check "changed legacy path-only file remains untouched" "grep -q 'USER CHANGED LEGACY FILE' '$T/collab/ask.sh'"
rm -rf "$S" "$T"

# --- surviving hashes work without a manifest across source upgrades ----------
S="$(mktempd)"; cp -R "$repo_root/." "$S/"
T="$(newrepo)"
bash "$S/install.sh" --dest "$T" >/dev/null 2>&1
rm -f "$T/collab/.install-manifest"
printf '\n# NEWER SOURCE PAYLOAD\n' >> "$S/collab/ask.sh"
bash "$S/install.sh" --dest "$T" >/dev/null 2>&1
check "orphaned hash upgrades an older installed payload" "grep -q 'NEWER SOURCE PAYLOAD' '$T/collab/ask.sh'"
check "orphaned hash migration restores the manifest" "grep -qx 'collab/ask.sh' '$T/collab/.install-manifest'"
check "orphaned hash migration refreshes ownership metadata" "grep -q $'\\tcollab/ask.sh$' '$T/collab/.install-hashes'"
rm -rf "$S" "$T"

# --- explicit payload inventory excludes local/generated/arbitrary files ------
S="$(mktempd)"
cp -R "$repo_root/." "$S/"
mkdir -p "$S/collab/logs/run"
printf 'private\n' > "$S/collab/collab.conf.local"
printf 'stale\n' > "$S/collab/.install-manifest"
printf 'log\n' > "$S/collab/logs/run/calls.jsonl"
printf 'arbitrary\n' > "$S/collab/not-payload.txt"
T="$(newrepo)"
bash "$S/install.sh" --dest "$T" >/dev/null 2>&1
check "payload excludes personal config" "[ ! -e '$T/collab/collab.conf.local' ]"
check "payload excludes source logs" "[ ! -e '$T/collab/logs/run/calls.jsonl' ]"
check "payload excludes arbitrary source files" "[ ! -e '$T/collab/not-payload.txt' ]"
check "payload does not copy a stale source manifest" "! grep -q stale '$T/collab/.install-manifest'"
expected="$T/.expected-payload"; actual="$T/.actual-payload"
( cd "$repo_root" && {
    find .claude/commands/collab .opencode/agent collab -type f \
      ! -path 'collab/logs/*' \
      ! -name '.install-manifest' ! -name '.install-hashes' ! -name '.install-state' \
      ! -name 'collab.conf.local' ! -name 'models.policy.local' -print
  } | sed 's|^\\./||' | sort ) > "$expected"
sort "$T/collab/.install-manifest" > "$actual"
check "explicit payload inventory includes every intended source file" "cmp -s '$expected' '$actual'"
rm -rf "$S" "$T"

# --- no-source/no-manifest uninstall refuses path-only deletion ---------------
S="$(mktempd)"; cp "$installer" "$S/install.sh"
T="$(newrepo)"; mkdir -p "$T/collab"; printf 'USER FILE\n' > "$T/collab/ask.sh"
bash "$S/install.sh" --uninstall --dest "$T" >/dev/null 2>&1
check "no-source uninstall preserves known-path user files" "grep -q 'USER FILE' '$T/collab/ask.sh'"
rm -rf "$S" "$T"

# --- symlink components and destination files are rejected -------------------
for parent in collab .claude; do
  T="$(newrepo)"; outside="$(mktempd)"
  ln -s "$outside" "$T/$parent"
  if bash "$installer" --dest "$T" >/dev/null 2>&1; then
    no "install rejects symlinked $parent parent"
  else
    ok "install rejects symlinked $parent parent"
  fi
  check "symlinked $parent parent cannot write outside dest" "[ -z \"\$(ls -A '$outside')\" ]"
  rm -rf "$T" "$outside"
done

# --- uninstall preserves pre-existing .gitignore identity and blank lines -----
T="$(newrepo)"; : > "$T/.gitignore"
bash "$installer" --dest "$T" >/dev/null 2>&1
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "uninstall keeps a pre-existing empty .gitignore" "[ -f '$T/.gitignore' ] && [ ! -s '$T/.gitignore' ]"
rm -rf "$T"

T="$(newrepo)"
printf 'keep-me\n\n\n' > "$T/.gitignore"
cp "$T/.gitignore" "$T/.gitignore.before"
bash "$installer" --dest "$T" >/dev/null 2>&1
bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1
check "gitignore block removal preserves unrelated trailing blank lines" "cmp -s '$T/.gitignore.before' '$T/.gitignore'"
rm -rf "$T"

T="$(newrepo)"; outside="$(mktempd)"; target="$outside/target"
mkdir -p "$T/collab"; printf 'OUTSIDE\n' > "$target"; ln -s "$target" "$T/collab/ask.sh"
if bash "$installer" --dest "$T" >/dev/null 2>&1; then
  no "install rejects a destination file symlink"
else
  ok "install rejects a destination file symlink"
fi
check "destination file symlink target is untouched" "grep -q OUTSIDE '$target'"
rm -rf "$T" "$outside"

# The old fixed .gitignore.cctmp name allowed a same-directory symlink escape.
T="$(newrepo)"; outside="$(mktempd)"; target="$outside/target"
bash "$installer" --dest "$T" >/dev/null 2>&1
printf 'OUTSIDE\n' > "$target"; ln -s "$target" "$T/.gitignore.cctmp"
bash "$installer" --dest "$T" >/dev/null 2>&1
check "predictable gitignore temp symlink target is untouched" "grep -qx OUTSIDE '$target'"
check "gitignore replacement remains valid with hostile old temp path" "grep -q 'ClaudeCollab >>>' '$T/.gitignore'"
rm -rf "$T" "$outside"

T="$(newrepo)"; outside="$(mktempd)"; target="$outside/target"
bash "$installer" --dest "$T" >/dev/null 2>&1
rm -f "$T/collab/ask.sh"; printf 'OUTSIDE\n' > "$target"; ln -s "$target" "$T/collab/ask.sh"
if bash "$installer" --uninstall --dest "$T" >/dev/null 2>&1; then
  no "uninstall rejects a destination file symlink"
else
  ok "uninstall rejects a destination file symlink"
fi
check "uninstall cannot remove a destination symlink target" "grep -q OUTSIDE '$target'"
rm -rf "$T" "$outside"

# A symlink in the dest PREFIX is resolved and FOLLOWED, not refused — macOS /tmp
# and /var are OS-level symlinks, and a project can live under a symlinked mount, so
# refusing this broke the platform outright. The user named --dest; following it is
# intent, and `into: <resolved>` reports it. Newlines are valid in a component and
# must survive the walk (a first-line-only parse once mishandled them); after `cd`
# canonicalizes the prefix away, the working dest is the real target with no newline.
# Per-file protection is unchanged and asserted separately (the ask.sh file-symlink
# cases above), so this checks only that the prefix resolves and the install lands
# in the real target rather than erroring.
base="$(mktempd)"; outside="$(mktempd)"; component=$'linked\ncomponent'
ln -s "$outside" "$base/$component"
( cd "$outside" && git init -q ) 2>/dev/null
T="$base/$component/project"
bash "$installer" --dest "$T" >/dev/null 2>&1
check "symlinked dest prefix is resolved and installed into the real target" "[ -f '$outside/project/collab/ask.sh' ]"
rm -rf "$base" "$outside"

# A dangling symlink prefix has no real target to resolve to, so it must still fail
# — cleanly, via mkdir/cd, not by installing somewhere unexpected.
base="$(mktempd)"
ln -s "$base/does-not-exist" "$base/dangling"
if bash "$installer" --dest "$base/dangling/project" >/dev/null 2>&1; then
  no "install proceeded through a dangling symlink destination prefix"
else
  ok "install fails cleanly on a dangling symlink destination prefix"
fi
rm -rf "$base"

# --- dest path containing a space --------------------------------------------
base="$(mktempd)"; T="$base/with space"; mkdir -p "$T"; ( cd "$T" && git init -q ) 2>/dev/null
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

# --- ref selection on the fetch path -----------------------------------------
# Builds a throwaway "origin" with two release tags and a diverged default
# branch, each stamping a different marker into an installed file, so which ref
# was cloned is observable in the destination. CLAUDECOLLAB_REPO points at it
# over file://, so this stays offline. The installer is copied somewhere with no
# payload beside it to force the fetch path — i.e. to simulate curl … | bash.
stamp_and_tag() { # <marker> [tag]
  printf '# marker: %s\n' "$1" >> collab/ask.sh
  git add -A && git commit -qm "$1"
  [ $# -ge 2 ] && git tag "$2"
  return 0
}
origin="$(mktempd)"; standalone="$(mktempd)"
git clone -q "$repo_root" "$origin" 2>/dev/null
# The clone carries the *committed* installer; this suite must exercise the
# working-tree one, so overwrite it before the fixture commits are made.
cp "$installer" "$origin/install.sh"
(
  cd "$origin" || exit 1
  git config user.email t@t; git config user.name t
  git checkout -q -B main
  stamp_and_tag v0.1.0-payload v0.1.0
  stamp_and_tag v0.2.0-payload v0.2.0
  stamp_and_tag main-tip-payload
) >/dev/null 2>&1
cp "$installer" "$standalone/install.sh"

T="$(newrepo)"
CLAUDECOLLAB_REPO="file://$origin" bash "$standalone/install.sh" --dest "$T" >/dev/null 2>&1
check "fetch path defaults to the latest release tag, not the default branch" \
  "grep -q 'v0.2.0-payload' '$T/collab/ask.sh' && ! grep -q 'main-tip-payload' '$T/collab/ask.sh'"
rm -rf "$T"

T="$(newrepo)"
CLAUDECOLLAB_REPO="file://$origin" bash "$standalone/install.sh" --dest "$T" --ref v0.1.0 >/dev/null 2>&1
check "--ref pins an older release tag" \
  "grep -q 'v0.1.0-payload' '$T/collab/ask.sh' && ! grep -q 'v0.2.0-payload' '$T/collab/ask.sh'"
rm -rf "$T"

T="$(newrepo)"
CLAUDECOLLAB_REPO="file://$origin" bash "$standalone/install.sh" --dest "$T" --ref main >/dev/null 2>&1
check "--ref main tracks the development branch" \
  "grep -q 'main-tip-payload' '$T/collab/ask.sh'"
rm -rf "$T"

T="$(newrepo)"
CLAUDECOLLAB_REF=v0.1.0 CLAUDECOLLAB_REPO="file://$origin" bash "$standalone/install.sh" --dest "$T" >/dev/null 2>&1
check "CLAUDECOLLAB_REF pins a ref like --ref does" \
  "grep -q 'v0.1.0-payload' '$T/collab/ask.sh'"
rm -rf "$T"

# An explicit --ref must win over the clone the script sits in, or a user who
# named a version would silently get whatever that clone was checked out at.
T="$(newrepo)"
CLAUDECOLLAB_REPO="file://$origin" bash "$origin/install.sh" --dest "$T" --ref v0.1.0 >/dev/null 2>&1
check "--ref fetches even when run from a clone" \
  "grep -q 'v0.1.0-payload' '$T/collab/ask.sh' && ! grep -q 'main-tip-payload' '$T/collab/ask.sh'"
rm -rf "$T"

# ...but with no --ref, a clone still installs itself, unchanged from before.
T="$(newrepo)"
bash "$origin/install.sh" --dest "$T" >/dev/null 2>&1
check "a clone with no --ref still installs its own payload" \
  "grep -q 'main-tip-payload' '$T/collab/ask.sh'"
rm -rf "$T"

T="$(newrepo)"
if CLAUDECOLLAB_REPO="file://$origin" bash "$standalone/install.sh" --dest "$T" --ref -oops >/dev/null 2>&1; then
  no "an option-shaped ref should be refused (exit non-zero)"
else
  ok "refuses an option-shaped ref"
fi
rm -rf "$T"

# No release tags at all: fall back to the default branch rather than failing.
# This is also the pre-first-release state, so it must not be a hard error.
untagged="$(mktempd)"
git clone -q "$origin" "$untagged" 2>/dev/null
( cd "$untagged" && git tag -d v0.1.0 v0.2.0 ) >/dev/null 2>&1
T="$(newrepo)"
CLAUDECOLLAB_REPO="file://$untagged" bash "$standalone/install.sh" --dest "$T" >/dev/null 2>&1
check "falls back to the default branch when the repo has no release tags" \
  "grep -q 'main-tip-payload' '$T/collab/ask.sh'"
rm -rf "$T" "$untagged" "$origin" "$standalone"

# ==================== GLOBAL (user-level) install mode =======================
# Slice B1. Every invocation below is sandboxed with HOME=<tmp> XDG_CONFIG_HOME=<tmp>/.config
# via gi(), so it lands entirely in temp; real_before/real_after prove the real home
# was never touched. NO slash commands are installed this slice (a later one does that).
real_before="$(real_marker)"

# --- fresh --global install --------------------------------------------------
G="$(gsandbox)"
gi "$G" >/dev/null 2>&1
cdir="$(cd "$G/.claude" && pwd -P)"
oadir="$(cd "$G/.config/opencode/agent" && pwd -P)"
check "global: agent def lands in the opencode global agent dir" "[ -f '$oadir/collab-read.md' ]"
check "global: all four agent defs land flat"                    "[ -f '$oadir/collab-build.md' ] && [ -f '$oadir/collab-research.md' ] && [ -f '$oadir/collab-watch.md' ]"
check "global: scripts land under ~/.claude/collab"              "[ -f '$cdir/collab/ask.sh' ] && [ -f '$cdir/collab/log.sh' ] && [ -f '$cdir/collab/tests/run-tests.sh' ]"
check "global: installed ask.sh is executable"                   "[ -x '$cdir/collab/ask.sh' ]"
check "global: installed fake-opencode is executable"            "[ -x '$cdir/collab/tests/fake-opencode' ]"
check "global: a non-script payload file is not chmod'd"         "[ ! -x '$cdir/collab/models.policy' ]"
check "global: all nine slash commands land in commands/collab"  "[ -f '$cdir/commands/collab/collaborate.md' ] && [ -f '$cdir/commands/collab/configure.md' ] && [ -f '$cdir/commands/collab/consult.md' ] && [ -f '$cdir/commands/collab/delegate.md' ] && [ -f '$cdir/commands/collab/panel.md' ] && [ -f '$cdir/commands/collab/research.md' ] && [ -f '$cdir/commands/collab/review.md' ] && [ -f '$cdir/commands/collab/witness.md' ] && [ -f '$cdir/commands/collab/workshop.md' ]"
check "global: conf.local has COLLAB_AGENT_DIR (resolved)"       "grep -qx 'COLLAB_AGENT_DIR=$oadir' '$cdir/collab/collab.conf.local'"
check "global: conf.local has COLLAB_LOG_PARTITION=1"            "grep -qx 'COLLAB_LOG_PARTITION=1' '$cdir/collab/collab.conf.local'"
check "global: NO .gitignore block is written in home"           "[ ! -e '$G/.gitignore' ] && [ ! -e '$cdir/.gitignore' ]"
check "global: writes a global manifest under a DISTINCT name"   "[ -f '$cdir/collab/.install-manifest.global' ] && [ ! -e '$cdir/collab/.install-manifest' ]"
check "global: writes global hashes under a distinct name"       "[ -f '$cdir/collab/.install-hashes.global' ]"
check "global: manifest records the RESOLVED ABSOLUTE path"      "grep -qx '$cdir/collab/ask.sh' '$cdir/collab/.install-manifest.global'"
rm -rf "$G"

# --- SLICE B2/C: slash commands installed with invocations rewritten absolute -
G="$(gsandbox)"
gi "$G" >/dev/null 2>&1
cdir="$(cd "$G/.claude" && pwd -P)"
resid="$(grep -rl 'bash collab/' "$cdir/commands/collab/" 2>/dev/null || true)"
check "global commands: NO residual relative 'bash collab/' in ANY command"     "[ -z '$resid' ]"
check "global commands: a BODY invocation uses the absolute script path"        "grep -qF 'bash $cdir/collab/ask.sh -m <provider/model>' '$cdir/commands/collab/panel.md'"
check "global commands: an allowed-tools GRANT uses the absolute script path"   "head -6 '$cdir/commands/collab/panel.md' | grep -qF 'Bash(bash $cdir/collab/ask.sh:*)'"
check "global commands: the RUN=\$(...) substitution grant was rewritten"       "grep -qF 'RUN=\$(bash $cdir/collab/log.sh new-run:*)' '$cdir/commands/collab/panel.md'"
check "global commands: an env-prefixed grant was rewritten"                    "grep -qF 'COLLAB_COMMAND=/collab:panel bash $cdir/collab/ask.sh:*' '$cdir/commands/collab/panel.md'"
check "global commands: the witness piped grant was rewritten"                  "grep -qF 'printf *| bash $cdir/collab/log.sh final:*' '$cdir/commands/collab/witness.md'"
check "global commands: bare PROSE path collab/models.policy is left untouched" "grep -qF 'collab/models.policy' '$cdir/commands/collab/consult.md'"
check "global commands: a command is recorded in the global manifest"           "grep -qx '$cdir/commands/collab/panel.md' '$cdir/collab/.install-manifest.global'"
# byte-exactness: installed file must equal the intended bash-literal transform
src_cmd="$repo_root/.claude/commands/collab/panel.md"
exp="$(cat "$src_cmd"; printf x)"; exp="${exp%x}"; exp="${exp//bash collab\//bash $cdir/collab/}"
printf '%s' "$exp" > "$G/.exp.md"
check "global commands: installed file is byte-identical to the literal transform" "cmp -s '$G/.exp.md' '$cdir/commands/collab/panel.md'"
rm -rf "$G"

# --- command templating is a LITERAL replacement: a '\' or '&' in CLAUDE_DIR ---
# round-trips byte-exactly (sed/awk would reinterpret them — same class as awk -v).
G="$(gsandbox)"; sh="$G/h\\x&y"
if mkdir -p "$sh" 2>/dev/null && [ -d "$sh" ]; then
  HOME="$sh" XDG_CONFIG_HOME="$G/.config" bash "$installer" --global >/dev/null 2>&1
  cdir="$(cd "$sh/.claude" && pwd -P)"
  exp="$(cat "$repo_root/.claude/commands/collab/panel.md"; printf x)"; exp="${exp%x}"
  exp="${exp//bash collab\//bash $cdir/collab/}"
  printf '%s' "$exp" > "$G/.exp2.md"
  check "global commands \\&: literal transform round-trips byte-exactly"        "cmp -s '$G/.exp2.md' '$cdir/commands/collab/panel.md'"
  check "global commands \\&: NO residual 'bash collab/' remains"                "! grep -q 'bash collab/' '$cdir/commands/collab/panel.md'"
else
  ok "global commands \\& [FS rejects such names]: skipped; literal transform proven for the normal path above"
fi
rm -rf "$G"

# --- uninstall removes commands and prunes empty command dirs ----------------
G="$(gsandbox)"
gi "$G" >/dev/null 2>&1
cdir="$(cd "$G/.claude" && pwd -P)"
gi "$G" --uninstall >/dev/null 2>&1
check "global uninstall: removes installed commands"            "[ ! -e '$cdir/commands/collab/panel.md' ]"
check "global uninstall: prunes empty commands/collab + commands" "[ ! -d '$cdir/commands/collab' ] && [ ! -d '$cdir/commands' ]"
rm -rf "$G"

# --- skip-not-clobber for a user's same-path command; user's OTHER cmd survives
G="$(gsandbox)"
mkdir -p "$G/.claude/commands/collab"
printf 'USER COMMAND\n' > "$G/.claude/commands/collab/panel.md"
printf 'my other\n'     > "$G/.claude/commands/mine.md"
gcout="$G/.gc.txt"
gi "$G" > "$gcout" 2>&1
cdir="$(cd "$G/.claude" && pwd -P)"
check "global command skip: does NOT overwrite a user's same-path command"      "grep -qx 'USER COMMAND' '$G/.claude/commands/collab/panel.md'"
check "global command skip: other 8 commands still install"                     "[ -f '$cdir/commands/collab/consult.md' ]"
check "global command skip: the skip is summarised by name"                     "grep -q 'were NOT installed' '$gcout'"
check "global command skip: the skipped command is not recorded as owned"       "! grep -q 'commands/collab/panel.md$' '$cdir/collab/.install-manifest.global'"
gi "$G" --uninstall >/dev/null 2>&1
check "global command skip: uninstall does NOT delete the user's command"       "grep -qx 'USER COMMAND' '$G/.claude/commands/collab/panel.md'"
check "global command skip: user's OTHER command keeps commands/ alive"         "[ -f '$G/.claude/commands/mine.md' ]"
rm -rf "$G"

# --- conf.local MERGE (never clobber an existing conf) -----------------------
G="$(gsandbox)"; mkdir -p "$G/.claude/collab"
printf 'COLLAB_MODEL=x/y\n# a comment\nCOLLAB_MODELS=a/b c/d\n' > "$G/.claude/collab/collab.conf.local"
gi "$G" >/dev/null 2>&1
oadir="$(cd "$G/.config/opencode/agent" && pwd -P)"
conf="$G/.claude/collab/collab.conf.local"
check "global merge: pre-existing COLLAB_MODEL line survives"    "grep -qx 'COLLAB_MODEL=x/y' '$conf'"
check "global merge: pre-existing comment + COLLAB_MODELS survive" "grep -qx '# a comment' '$conf' && grep -qx 'COLLAB_MODELS=a/b c/d' '$conf'"
check "global merge: adds COLLAB_AGENT_DIR"                      "grep -qx 'COLLAB_AGENT_DIR=$oadir' '$conf'"
check "global merge: adds COLLAB_LOG_PARTITION=1"                "grep -qx 'COLLAB_LOG_PARTITION=1' '$conf'"
gi "$G" >/dev/null 2>&1                                          # re-install must not duplicate
na=$(grep -c '^COLLAB_AGENT_DIR=' "$conf"); np=$(grep -c '^COLLAB_LOG_PARTITION=1' "$conf"); nm=$(grep -c '^COLLAB_MODEL=' "$conf")
check "global merge: re-install keeps exactly one of each key"   "[ '$na' -eq 1 ] && [ '$np' -eq 1 ] && [ '$nm' -eq 1 ]"
rm -rf "$G"

# --- FIX 1: a backslash in the agent-dir path round-trips identically ---------
# The MERGE branch used to pass the path through `awk -v`, whose backslash-escape
# processing corrupted a '\'-bearing path while the fresh (printf) branch wrote it
# correctly — so a re-install silently rewrote a correct value to a wrong one. The
# fix (ENVIRON) must make fresh and merge byte-identical. XDG_CONFIG_HOME is custom
# here (a component with a literal backslash), so this bypasses gi()'s fixed XDG.
G="$(gsandbox)"; bxdg="$G/cfg\\back"
if mkdir -p "$bxdg" 2>/dev/null && [ -d "$bxdg" ]; then
  HOME="$G" XDG_CONFIG_HOME="$bxdg" bash "$installer" --global >/dev/null 2>&1   # fresh
  oadir="$(cd "$bxdg/opencode/agent" && pwd -P)"
  fresh_val="$(grep '^COLLAB_AGENT_DIR=' "$G/.claude/collab/collab.conf.local" | head -1)"
  HOME="$G" XDG_CONFIG_HOME="$bxdg" bash "$installer" --global >/dev/null 2>&1   # merge
  merge_val="$(grep '^COLLAB_AGENT_DIR=' "$G/.claude/collab/collab.conf.local" | head -1)"
  check "global backslash: fresh and merge COLLAB_AGENT_DIR are byte-identical" "[ '$fresh_val' = '$merge_val' ]"
  check "global backslash: the value equals the real resolved agent dir"        "[ '$merge_val' = 'COLLAB_AGENT_DIR=$oadir' ]"
else
  # FS rejected a backslash filename: fall back to proving fresh==merge for a normal
  # path (still exercises both branches), and note the FS limitation in the name.
  gi "$G" >/dev/null 2>&1
  oadir="$(cd "$G/.config/opencode/agent" && pwd -P)"
  fresh_val="$(grep '^COLLAB_AGENT_DIR=' "$G/.claude/collab/collab.conf.local" | head -1)"
  gi "$G" >/dev/null 2>&1
  merge_val="$(grep '^COLLAB_AGENT_DIR=' "$G/.claude/collab/collab.conf.local" | head -1)"
  check "global backslash [FS lacks '\\' names]: fresh==merge for a normal path"  "[ '$fresh_val' = '$merge_val' ] && [ '$merge_val' = 'COLLAB_AGENT_DIR=$oadir' ]"
fi
rm -rf "$G"

# --- FIX 2: COLLAB_LOG_PARTITION is set-if-absent, never overriding the user --
G="$(gsandbox)"; mkdir -p "$G/.claude/collab"
printf 'COLLAB_LOG_PARTITION=0\n' > "$G/.claude/collab/collab.conf.local"
gi "$G" >/dev/null 2>&1
conf="$G/.claude/collab/collab.conf.local"
oadir="$(cd "$G/.config/opencode/agent" && pwd -P)"
check "global partition: a user's COLLAB_LOG_PARTITION=0 is preserved (not flipped)" "grep -qx 'COLLAB_LOG_PARTITION=0' '$conf' && ! grep -q '^COLLAB_LOG_PARTITION=1' '$conf'"
check "global partition: COLLAB_AGENT_DIR is still written alongside the kept =0"    "grep -qx 'COLLAB_AGENT_DIR=$oadir' '$conf'"
rm -rf "$G"

G="$(gsandbox)"; mkdir -p "$G/.claude/collab"
printf 'COLLAB_MODEL=x/y\n' > "$G/.claude/collab/collab.conf.local"       # key absent
gi "$G" >/dev/null 2>&1
check "global partition: an absent COLLAB_LOG_PARTITION defaults to =1"              "grep -qx 'COLLAB_LOG_PARTITION=1' '$G/.claude/collab/collab.conf.local'"
rm -rf "$G"

# --- SYMLINKED ~/.claude is resolved to its physical target ------------------
G="$(gsandbox)"; real="$(mktempd)"
ln -s "$real" "$G/.claude"
gi "$G" >/dev/null 2>&1
oadir="$(cd "$G/.config/opencode/agent" && pwd -P)"
check "global symlink: install writes to the PHYSICAL ~/.claude target" "[ -f '$real/collab/ask.sh' ]"
check "global symlink: manifest records the physical absolute path"     "grep -qx '$real/collab/ask.sh' '$real/collab/.install-manifest.global'"
check "global symlink: conf COLLAB_AGENT_DIR is the physical agent dir"  "grep -qx 'COLLAB_AGENT_DIR=$oadir' '$real/collab/collab.conf.local'"
rm -rf "$G" "$real"

# --- uninstall --global removes exactly what it installed, across both roots --
G="$(gsandbox)"
gi "$G" >/dev/null 2>&1
cdir="$(cd "$G/.claude" && pwd -P)"; oadir="$(cd "$G/.config/opencode/agent" && pwd -P)"
mkdir -p "$cdir/collab/logs/run1"; printf 'log\n' > "$cdir/collab/logs/run1/calls.jsonl"
printf 'my own tool\n' > "$cdir/collab/mytool.sh"
gi "$G" --uninstall >/dev/null 2>&1
check "global uninstall: removes installed scripts"             "[ ! -e '$cdir/collab/ask.sh' ]"
check "global uninstall: removes installed agent defs"          "[ ! -e '$oadir/collab-read.md' ]"
check "global uninstall: leaves a user-created file intact"     "grep -qx 'my own tool' '$cdir/collab/mytool.sh'"
check "global uninstall: leaves collab/logs/ intact"            "[ -f '$cdir/collab/logs/run1/calls.jsonl' ]"
check "global uninstall: leaves conf.local intact"              "[ -f '$cdir/collab/collab.conf.local' ]"
check "global uninstall: prunes the now-empty tests dir"        "[ ! -d '$cdir/collab/tests' ]"
check "global uninstall: prunes the now-empty agent dir"        "[ ! -d '$oadir' ]"
check "global uninstall: removes its own manifest + hashes"     "[ ! -e '$cdir/collab/.install-manifest.global' ] && [ ! -e '$cdir/collab/.install-hashes.global' ]"
rm -rf "$G"

# --- a same-path user file is never clobbered (install OR uninstall) ----------
G="$(gsandbox)"
mkdir -p "$G/.config/opencode/agent" "$G/.claude/collab"
printf 'USER AGENT\n' > "$G/.config/opencode/agent/collab-read.md"
printf 'USER SCRIPT\n' > "$G/.claude/collab/ask.sh"
gout="$G/.gout.txt"
gi "$G" > "$gout" 2>&1
check "global skip: does NOT overwrite a user's same-path agent def" "grep -qx 'USER AGENT' '$G/.config/opencode/agent/collab-read.md'"
check "global skip: does NOT overwrite a user's same-path script"    "grep -qx 'USER SCRIPT' '$G/.claude/collab/ask.sh'"
check "global skip: summarises the skips by name"                    "grep -q 'were NOT installed' '$gout'"
check "global skip: a skipped file is not recorded as owned"         "! grep -q 'collab/ask.sh$' '$G/.claude/collab/.install-manifest.global' && ! grep -q 'agent/collab-read.md$' '$G/.claude/collab/.install-manifest.global'"
gi "$G" --uninstall >/dev/null 2>&1
check "global skip: uninstall does NOT delete the user's agent def"  "grep -qx 'USER AGENT' '$G/.config/opencode/agent/collab-read.md'"
check "global skip: uninstall does NOT delete the user's script"     "grep -qx 'USER SCRIPT' '$G/.claude/collab/ask.sh'"
rm -rf "$G"

# --- ISOLATION: a per-project install and a --global install never cross ------
G="$(gsandbox)"; P="$(newrepo)"
bash "$installer" --dest "$P" >/dev/null 2>&1
gi "$G" >/dev/null 2>&1
cdir="$(cd "$G/.claude" && pwd -P)"; oadir="$(cd "$G/.config/opencode/agent" && pwd -P)"
check "isolation: per-project uses the plain manifest name"     "[ -f '$P/collab/.install-manifest' ] && [ ! -e '$P/collab/.install-manifest.global' ]"
check "isolation: global uses the .global manifest name"        "[ -f '$cdir/collab/.install-manifest.global' ] && [ ! -e '$cdir/collab/.install-manifest' ]"
bash "$installer" --uninstall --dest "$P" >/dev/null 2>&1
check "isolation: per-project uninstall leaves global scripts"  "[ -f '$cdir/collab/ask.sh' ]"
check "isolation: per-project uninstall leaves global agent defs" "[ -f '$oadir/collab-read.md' ]"
bash "$installer" --dest "$P" >/dev/null 2>&1                   # reinstall project, then remove global
gi "$G" --uninstall >/dev/null 2>&1
check "isolation: global uninstall leaves per-project scripts"  "[ -f '$P/collab/ask.sh' ]"
check "isolation: global uninstall leaves per-project commands" "[ -f '$P/.claude/commands/collab/consult.md' ]"
rm -rf "$G" "$P"

# --- --global and --dest are mutually exclusive ------------------------------
G="$(gsandbox)"; P="$(mktempd)"
if HOME="$G" XDG_CONFIG_HOME="$G/.config" bash "$installer" --global --dest "$P" >/dev/null 2>&1; then
  no "global: --global combined with --dest is refused"
else
  ok "global: --global combined with --dest is refused"
fi
rm -rf "$G" "$P"

# --- --global refuses a resolved path containing whitespace ------------------
# A command file bakes CLAUDE_DIR into its body/grants as an UNQUOTED token, so a
# space in the path would word-split at runtime and silently break every command.
# The installer must fail closed (install path only) rather than write broken files.
G="$(gsandbox)"; ws="$G/a b"; mkdir -p "$ws"
wout="$G/.ws.txt"
if HOME="$ws" XDG_CONFIG_HOME="$G/.config" bash "$installer" --global > "$wout" 2>&1; then
  no "global: refuses a HOME path containing whitespace"
else
  ok "global: refuses a HOME path containing whitespace"
fi
check "global whitespace: prints an actionable refusal mentioning whitespace" "grep -qi 'whitespace' '$wout'"
nf="$(find "$ws" -type f 2>/dev/null | head -1)"
check "global whitespace: writes NO files under the space-bearing home"        "[ -z '$nf' ]"
rm -rf "$G"

# --- the real home must never have been touched by any of the above ----------
real_after="$(real_marker)"
if [ "$real_before" = "$real_after" ]; then
  ok "global: nothing under the real \$HOME/.claude or \$XDG opencode agent dir was touched"
else
  no "global: the real \$HOME was modified by a sandboxed --global run"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
