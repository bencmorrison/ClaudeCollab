#!/usr/bin/env bash
# check-shellcheck.sh — run ShellCheck over every tracked shell script in the repo,
# at the SAME severity and shell dialect CI uses, so a dev can reproduce the Linux
# lint locally instead of discovering it on a push.
#
# Single source of truth: CI calls THIS script rather than duplicating the shellcheck
# invocation, so the file set + flags can never drift between local and CI.
#
# It inspects every file git tracks whose first two bytes are `#!` — not just *.sh —
# the same robust gathering check-shebangs.sh uses, so an extension-less script (like
# collab/tests/fake-opencode) is covered too. Every such file is asserted to be a
# `#!/usr/bin/env bash` script by check-shebangs.sh, so linting them all as bash is safe.
#
# Skips cleanly (exit 0) when shellcheck is not installed: shellcheck is a static
# analyser with identical results on any OS, so CI's Linux job is the enforcer (it
# apt-installs it); the macOS job, an installed user, or a dev without it simply skip.
# Install locally with:  brew install shellcheck   (or: apt-get install shellcheck)
#
# Usage:
#   bash collab/tests/check-shellcheck.sh            # every tracked shell script
#   bash collab/tests/check-shellcheck.sh <file>...  # only these (used by the tests)
# Exit 0 = clean (or shellcheck absent); non-zero = ShellCheck found a warning+.
set -uo pipefail

SEVERITY=warning

# --self-test: prove THIS lint skips cleanly without shellcheck, and (when shellcheck is
# present) accepts a clean script and catches a warning-level finding (ported from the
# retired run-tests.sh meta-tests). Runs before the absent-guard so the skip path is tested.
if [ "${1:-}" = "--self-test" ]; then
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  st_fail=0
  st_ok() { printf '\033[32mok\033[0m   self-test: %s\n' "$1"; }
  st_no() { printf '\033[31mFAIL\033[0m self-test: %s\n' "$1"; st_fail=1; }
  d="$(mktemp -d "${TMPDIR:-/tmp}/collab-scc.XXXXXX")"
  # Skip-when-absent: an empty PATH makes shellcheck genuinely absent (the script runs no
  # external command before its skip-and-exit); bash is invoked by absolute path so the
  # child still starts. Stripping shellcheck's dir from PATH is unreliable on usrmerge Linux.
  self_bash="$(command -v bash)"
  printf '#!/usr/bin/env bash\necho hi\n' > "$d/none.sh"
  out="$(PATH=/nonexistent "$self_bash" "$self" "$d/none.sh" 2>&1)"; rc=$?
  { [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi 'not installed'; } \
    && st_ok "skips cleanly (exit 0 + note) when shellcheck is absent" \
    || st_no "did not skip cleanly without shellcheck (rc=$rc): $out"
  if command -v shellcheck >/dev/null 2>&1; then
    printf '#!/usr/bin/env bash\necho hi\n' > "$d/good.sh"
    bash "$self" "$d/good.sh" >/dev/null 2>&1 && st_ok "accepts a clean script" || st_no "rejects a clean script (false positive)"
    printf '#!/usr/bin/env bash\necho $(ls)\n' > "$d/bad.sh"   # SC2046 word-splitting
    bash "$self" "$d/bad.sh" >/dev/null 2>&1 && st_no "MISSED a warning-level issue (SC2046)" || st_ok "catches a warning-level issue (SC2046)"
  else
    st_ok "accept/catch cases skipped (shellcheck not installed here)"
  fi
  rm -rf "$d"
  echo
  if [ "$st_fail" -eq 0 ]; then printf '\033[32mshellcheck self-test: OK\033[0m\n'
  else printf '\033[31mshellcheck self-test: FAILED\033[0m\n'; fi
  exit "$st_fail"
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not installed — skipping (CI's Linux job enforces it). Install with: brew install shellcheck"
  exit 0
fi

if [ "$#" -gt 0 ]; then
  # Explicit paths (the meta-tests pass specific files); lint exactly those.
  files=("$@")
else
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "$repo_root" || exit 1
  files=()
  while IFS= read -r f; do
    [ -f "$f" ] && [ "$(head -c2 "$f" 2>/dev/null)" = '#!' ] && files+=("$f")
  done < <(git ls-files)
  # Finding no files means git listed nothing (not a checkout, or an empty tree),
  # not that the repo is clean — fail loudly rather than print a false all-clear.
  if [ "${#files[@]}" -eq 0 ]; then
    echo "FAIL: no tracked shell scripts found — not a clean pass (run from a git checkout)" >&2
    exit 1
  fi
fi

# Guard the empty-array expansion under `set -u` on bash 3.2 (stock macOS).
if shellcheck --severity="$SEVERITY" --shell=bash ${files[@]+"${files[@]}"}; then
  printf '\033[32mok\033[0m   shellcheck: %d shell file(s) clean (severity=%s)\n' "${#files[@]}" "$SEVERITY"
  exit 0
else
  printf '\033[31mFAIL\033[0m shellcheck found issues (severity=%s) — see above\n' "$SEVERITY" >&2
  exit 1
fi
