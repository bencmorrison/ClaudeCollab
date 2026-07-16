#!/usr/bin/env bash
# check-shebangs.sh — assert every script in the repo starts with exactly
#   #!/usr/bin/env bash
# Opencode-free and token-free, so CI and doctor.sh can both run it.
#
# Why env bash and not /bin/bash: `env` finds bash wherever it actually lives on
# PATH. `#!/bin/bash` is wrong on systems where bash isn't in /bin (NixOS, most
# BSDs, some minimal images), and on macOS it pins you to the stock bash 3.2 even
# when the user has a modern bash installed. `env bash` gets the user's real bash.
#   (Corollary for anyone adding macOS CI: because env bash prefers a Homebrew
#   bash 5 over the stock /bin/bash 3.2, a macOS job must invoke /bin/bash
#   EXPLICITLY to exercise the 3.2 worst case — see PLAN.md portability notes.)
#
# It inspects every file git tracks whose first two bytes are `#!` — not just
# *.sh — so an extension-less script (like collab/tests/fake-opencode) can't slip
# through, and neither can a future one.
#
# Usage:
#   bash collab/tests/check-shebangs.sh            # every tracked file
#   bash collab/tests/check-shebangs.sh <file>...  # only these (used by tests)
# Exit 0 = every shebang conforms.
set -uo pipefail

WANT='#!/usr/bin/env bash'

fail=0
pass() { printf '\033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '\033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=1; }

if [ "$#" -gt 0 ]; then
  # Explicit paths: the meta-tests pass non-scripts here on purpose and expect a
  # clean pass with nothing checked, so an empty result is legitimate.
  files=("$@")
else
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  cd "$repo_root" || exit 1
  # shellcheck disable=SC2207
  files=($(git ls-files))
  # Scanning the whole repo and finding no files means git listed nothing, not that
  # the repo conforms — without this the lint prints "all 0 conform" and exits 0,
  # the vacuous green that check-frontmatter.sh guards against for the same reason.
  if [ "${#files[@]}" -eq 0 ]; then
    printf '\033[31mFAIL\033[0m git ls-files returned nothing — this lint would otherwise pass vacuously\n' >&2
    exit 1
  fi
fi

checked=0
# `${files[@]+"${files[@]}"}`, not plain `"${files[@]}"`: under `set -u`, bash 3.2
# (stock macOS) treats an empty array's [@] expansion as unbound and aborts. Still
# reachable above via explicit empty args.
for f in ${files[@]+"${files[@]}"}; do
  [ -f "$f" ] || continue
  # Only files that actually declare an interpreter. Reading 2 bytes keeps binaries out.
  [ "$(head -c 2 "$f" 2>/dev/null)" = '#!' ] || continue
  checked=$((checked+1))
  line="$(head -n 1 "$f")"
  if [ "$line" = "$WANT" ]; then
    pass "$f"
  else
    bad "$f" "shebang is '$line', expected '$WANT'"
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mshebangs: all %d conform\033[0m (%s)\n' "$checked" "$WANT"
else
  printf '\033[31mshebangs: NON-CONFORMING\033[0m — use %s. If you deliberately added a\n' "$WANT"
  printf 'non-bash script, that is a real decision: update this lint and AGENTS.md together.\n'
fi
exit "$fail"
