#!/usr/bin/env bash
# Token-free checks for user-facing workflow names and command grants.
set -euo pipefail

script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${DOCS_LINT_ROOT:-$repo_root}" || exit 1

failed=0
bad() { printf 'FAIL: %s\n' "$*" >&2; failed=1; }

# Explicitly labelled rename/collision history is retained below. All other
# operational references, including elsewhere in those files, must be namespaced.
user_files=(
  .claude/commands/collab
  .devcontainer/Dockerfile
  .devcontainer/devcontainer.json
  .devcontainer/postCreate.sh
  AGENTS.md
  CONTRIBUTING.md
  PLAN.md
  README.md
  SECURITY.md
  collab/collab.conf.example
  collab/models.policy
)
obsolete='(^|[^[:alnum:]_.-])/((configure-collab)|(consult|panel|workshop|review|research|delegate|collaborate|witness|configure|consensus))([[:space:]<`"'"'"'(,.:]|$)'
obsolete_matches="$(grep -RInE --exclude=check-docs.sh "$obsolete" "${user_files[@]}" || true)"
obsolete_matches="$(printf '%s\n' "$obsolete_matches" | grep -Ev \
  '^AGENTS\.md:.*(where `/consult`, `/review` and `/panel`|Our `/review` was found colliding|Renamed from `/consensus`)|^PLAN\.md:.*(rename from `/consensus`|`/consensus` → `/collab:panel`|Found live: our `/review` was colliding)' || true)"
if [ -n "$obsolete_matches" ]; then
  printf '%s\n' "$obsolete_matches" >&2
  bad "obsolete unnamespaced command reference found; use /collab:<name>"
fi

if grep -RIn --include='*.md' 'Bash(bash collab/log\.sh:\*)' .claude/commands/collab README.md; then
  bad "broad log.sh grant found; allow only required subcommands"
fi

for command in panel workshop collaborate; do
  file=".claude/commands/collab/$command.md"
  if ! grep -Fq 'allowed-tools:' "$file" || ! grep -Fq 'Bash(RUN=$(bash collab/log.sh new-run:*))' "$file"; then
    bad "$command must grant the exact RUN=\$(bash collab/log.sh new-run ...) command"
  fi
  if ! grep -Fq 'RUN=$(bash collab/log.sh new-run' "$file"; then
    bad "$command no longer documents the new-run assignment its frontmatter grants"
  fi
  combined_grant="Bash(COLLAB_RUN_ID=* COLLAB_COMMAND=/collab:$command COLLAB_CONFIRMED=1 bash collab/ask.sh:*)"
  grep -m1 '^allowed-tools:' "$file" | grep -Fq "$combined_grant" \
    || bad "$command must grant the exact combined run-id, command, and confirmation invocation"
done

grep -Fq '"Bash(COLLAB_RUN_ID=* COLLAB_COMMAND=/collab:* COLLAB_CONFIRMED=1 bash collab/ask.sh:*)"' README.md \
  || bad "README optional permissions omit the combined run-id, command, and confirmation invocation"

delegate=.claude/commands/collab/delegate.md
grep -m1 '^allowed-tools:' "$delegate" | grep -Fq 'Read' || bad "delegate patch review requires Read in allowed-tools"
grep -Fq 'with the `Read` tool' "$delegate" || bad "delegate must review the recorded patch with Read"

review=.claude/commands/collab/review.md
grep -m1 '^allowed-tools:' "$review" | grep -Fq 'Bash(git ls-files:*)' || bad "review uses git ls-files but does not grant it"
grep -Fq '"Bash(git ls-files:*)"' README.md || bad "README optional permissions omit review's git ls-files command"

witness=.claude/commands/collab/witness.md
grep -Fq 'outside ASCII `[A-Za-z0-9._-]`' "$witness" || bad "witness report filename sanitization rule is missing"
grep -Fq 'use `model` if nothing remains' "$witness" || bad "witness filename empty-result fallback is missing"

lifecycle_files=(
  AGENTS.md
  README.md
  SECURITY.md
  CONTRIBUTING.md
  collab/collab.conf.example
  .claude/commands/collab
  .opencode/agent
)
if grep -RInE '([Tt]wo|2)[[:space:]]+(entries|writes|records|lines)[[:space:]]+per[[:space:]]+call|3 concurrent calls produce 6|three concurrent calls produce six|started\+completed sharing one' "${lifecycle_files[@]}"; then
  bad "stale two-entry evidence lifecycle claim found; current lifecycle is expected-call + started + completed"
fi
while IFS= read -r lifecycle_line; do
  case "$lifecycle_line" in
    *expected-call*) ;;
    *)
      printf '%s\n' "$lifecycle_line" >&2
      bad "started/completed presented as a complete lifecycle without expected-call"
      ;;
  esac
done < <(grep -RInE 'started[[:space:]]*[/+&][[:space:]]*completed([^[:alnum:]]|$)' "${lifecycle_files[@]}" || true)
for file in AGENTS.md README.md SECURITY.md; do
  grep -Fq 'expected-call' "$file" || bad "$file must document the expected-call lifecycle entry"
done

if ! grep -Fq 'PAYLOAD_FILES' AGENTS.md || ! grep -Fq 'check-docs.sh' install.sh; then
  bad "docs lint must be described in AGENTS.md and included in install.sh PAYLOAD_FILES"
fi

[ "$failed" -eq 0 ] || exit 1
echo "documentation workflow lint: PASS"

if [ "${1:-}" = "--self-test" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  baseline="$tmp/baseline"
  mkdir -p "$baseline/.claude/commands" "$baseline/.devcontainer" \
    "$baseline/.opencode" "$baseline/collab"
  cp -a .claude/commands/collab "$baseline/.claude/commands/"
  cp -a .opencode/agent "$baseline/.opencode/"
  cp -a AGENTS.md CONTRIBUTING.md PLAN.md README.md SECURITY.md install.sh "$baseline/"
  cp -a .devcontainer/Dockerfile .devcontainer/devcontainer.json \
    .devcontainer/postCreate.sh "$baseline/.devcontainer/"
  cp -a collab/collab.conf.example collab/models.policy "$baseline/collab/"

  self_test_failed=0
  expect_rejected() {
    local name="$1" fixture="$2"
    if DOCS_LINT_ROOT="$fixture" bash "$script_path" >/dev/null 2>&1; then
      printf 'FAIL: self-test accepted %s\n' "$name" >&2
      self_test_failed=1
    else
      printf 'PASS: rejects %s\n' "$name"
    fi
  }

  fixture="$tmp/broad-log-grant"
  cp -a "$baseline" "$fixture"
  printf '\n`Bash(bash collab/log.sh:*)`\n' >> "$fixture/README.md"
  expect_rejected "broad log grant" "$fixture"

  fixture="$tmp/obsolete-command"
  cp -a "$baseline" "$fixture"
  printf '\nRun `/review` for details.\n' >> "$fixture/README.md"
  expect_rejected "obsolete command name" "$fixture"

  fixture="$tmp/command-grant-mismatch"
  cp -a "$baseline" "$fixture"
  cat > "$fixture/.claude/commands/collab/panel.md" <<'EOF'
---
allowed-tools: Bash(RUN=$(bash collab/log.sh new-run:*)), Bash(COLLAB_RUN_ID=* COLLAB_COMMAND=/collab:workshop COLLAB_CONFIRMED=1 bash collab/ask.sh:*)
---
RUN=$(bash collab/log.sh new-run)
EOF
  expect_rejected "command/grant mismatch" "$fixture"

  fixture="$tmp/stale-lifecycle"
  cp -a "$baseline" "$fixture"
  printf '\nThe current lifecycle has two entries per call.\n' >> "$fixture/README.md"
  expect_rejected "stale current lifecycle wording" "$fixture"

  if ! DOCS_LINT_ROOT="$baseline" bash "$script_path" >/dev/null 2>&1; then
    printf 'FAIL: self-test rejected intentional historical passages\n' >&2
    self_test_failed=1
  else
    printf 'PASS: allows narrowly exempt historical passages\n'
  fi

  [ "$self_test_failed" -eq 0 ] || exit 1
  echo "documentation workflow lint self-tests: PASS"
fi
