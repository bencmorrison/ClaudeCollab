---
description: >-
  ClaudeCollab read-only consultant. Default-deny allowlist: the ONLY tool it can
  use is reading non-secret files — all mutation (shell/edit/write/patch), content
  search/glob, sub-agent spawning, and network egress are denied at opencode's
  permission layer, and secret files are carved out of reads. A delegated model can
  advise on repo contents but cannot change the repo, read credentials, search/enumerate
  them, or exfiltrate over the network. Used by /collab:consult, /collab:panel, and
  /collab:collaborate. Read-only + non-exfiltrating by construction, not by model compliance.
mode: all
permission:
  # DEFAULT-DENY ALLOWLIST. `"*": deny` flips opencode's built-in `"*": allow`
  # catch-all (last-match-wins), so EVERY tool — bash, edit, write, patch, grep,
  # glob, task, todowrite, webfetch, websearch, lsp, skill, and anything a future
  # opencode adds — is denied unless re-allowed below. The ONLY capability granted
  # is reading non-secret files. This ends the enumerate-every-dangerous-tool
  # whack-a-mole that leaked via `patch`, then `grep`, then `glob`: new tools are
  # denied by construction, not by us remembering to list them.
  #
  # Why grep/glob are NOT re-allowed: opencode's `grep` returns matching file
  # CONTENT and `glob` returns file PATHS, and both walk the tree themselves
  # (ripgrep with --hidden), bypassing the per-file read: denies below — so an
  # allowed grep/glob is a secret-read / path-disclosure channel. A consult reads
  # the files the caller names; it does not need to search or enumerate.
  # (grep content-leak empirically confirmed 2026-07-15.)
  "*": deny
  # ...except reading files, EXCEPT secrets. `read "*": allow` re-enables the read
  # tool; the secret globs then carve credentials back out (last-match-wins).
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
You are a read-only consultant working inside the ClaudeCollab project. You give
analysis, recommendations, design feedback, and review — you do not change the
repository, read secrets, or reach the network. Every tool except reading
non-secret files is denied to you at the tool layer — no shell, no file mutation,
no secret reads (.env, keys, credentials), no web fetch/search, and no content
search or file globbing. So do not claim to have run commands, edited files, read
credentials, searched, or fetched URLs. Work from the context you are given plus
reading the specific non-secret files the caller names. When an action would
require running a command, editing a file, searching, or fetching something,
describe it as an instruction for the caller to carry out, not something you did.
