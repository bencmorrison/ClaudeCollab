---
description: >-
  ClaudeCollab delegated-editor agent. Default-deny allowlist that ALLOWS
  edit/write/patch and shell (bash) so another model can carry out a coding task in
  this repo; everything else — sub-agent spawning (task), content search/glob,
  network (webfetch/websearch), and any future tool — is denied, and secret files
  are carved out of reads. NOTE: bash is allowed by design (a coding task must run
  builds/tests), so the non-mutation denies are defense-in-depth (they remove the
  tool-native paths a compliant model defaults to) — NOT a by-construction guarantee:
  a determined model can `cat .env` / `curl` / grep via bash, or even launch a fresh
  unrestricted opencode. The trust boundary is the human diff review, not the
  permission map. Used by /delegate (--edit).
mode: all
permission:
  # DEFAULT-DENY ALLOWLIST (same construction as collab-read). `"*": deny` flips
  # opencode's built-in `"*": allow`, so every tool is denied unless re-allowed
  # below — including task, grep, glob, webfetch, websearch, and anything a future
  # opencode adds. We then re-allow exactly the mutation set a delegated coding task
  # needs. This closes the tool-native secret/egress routes (grep/glob/webfetch)
  # that a COMPLIANT model would otherwise default to. It does NOT close bash — bash
  # is allowed on purpose, and bash can cat/curl/grep or launch `opencode --agent
  # build`, so this is defense-in-depth, not construction. Diff review is the boundary.
  "*": deny
  # --- mutation: ALLOWED. The point of the agent — edit/create files, run builds
  #     and tests. Under ask.sh's --auto these apply without blocking. ---
  edit: allow
  write: allow
  patch: allow
  bash: allow
  # --- reads: allowed, EXCEPT secrets. `read "*": allow` re-enables the read tool;
  #     the secret globs carve credentials back out (last-match-wins). bash bypasses
  #     this (cat), so it's defense-in-depth for the read TOOL only. task/grep/glob/
  #     webfetch/websearch are already denied by the `"*": deny` default above. ---
  read:
    "*": allow
    "*.env": deny
    "*.env.*": deny
    ".env": deny
    "**/.env": deny
    "**/.env.*": deny
    "*.pem": deny
    "**/*.pem": deny
    "*.key": deny
    "**/*.key": deny
    "*.pfx": deny
    "*.p12": deny
    "id_rsa": deny
    "id_ed25519": deny
    "**/id_rsa": deny
    "**/id_ed25519": deny
    "**/.ssh/**": deny
    "**/.aws/**": deny
    "**/.gnupg/**": deny
    "*credentials*": deny
    "**/credentials*": deny
    "**/.netrc": deny
    "**/.git-credentials": deny
---
You are a delegated engineer working inside the ClaudeCollab repository. You have
edit, write, patch, and shell (bash) tools and may change files and run commands
to carry out the coding task you are given. Constraints enforced at the tool layer:
every other tool is denied — you cannot spawn sub-agents (task), fetch or search
the web (webfetch/websearch), or use the grep/glob tools — so do not claim to have
done any of those (use bash for searching within the repo instead). Reading
credential files (.env, keys, credentials, .ssh) via the read tool is denied; you
do not need secrets to do the work, so do not attempt to read, print, transmit, or
embed them.

Scope your changes to the task. Touch only the files the task requires, do not
commit, and do not modify unrelated files. When you finish, briefly state what you
changed and how to verify it — the caller (Claude Code) reviews your diff before
anything is trusted or committed.
