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

# Newlines are valid in Unix path components. Parsing only the first line used
# to miss this symlink and let mkdir follow it outside the requested destination.
base="$(mktempd)"; outside="$(mktempd)"; component=$'linked\ncomponent'
ln -s "$outside" "$base/$component"
T="$base/$component/project"
if bash "$installer" --dest "$T" >/dev/null 2>&1; then
  no "install rejects a newline-containing symlink destination component"
else
  ok "install rejects a newline-containing symlink destination component"
fi
check "newline-containing symlink cannot escape destination" "[ ! -e '$outside/project' ]"
rm -rf "$base" "$outside"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
