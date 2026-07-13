# ClaudeCollab — project context

Lets **Claude Code** collaborate with **other LLMs** (OpenAI, GitHub Copilot, Google Gemini) via **opencode** as a subscription-auth gateway — no API keys. See [README.md](README.md) for full usage.

## Current state (as of setup)

- Slash commands live in `.claude/commands/`: `/consult` (second opinion, read-only), `/consensus` (multi-model synthesis), `/delegate` (hand a coding task to another model, then review its diff).
- All three shell out to `collab/ask.sh`, a wrapper over `opencode run` (`plan` agent = read-only, `build` agent = edits files).
- Dev container (`.devcontainer/`) runs Claude Code **and** opencode in-container. Auth is **in-container login**, persisted across rebuilds via named volumes (`claudecollab-claude`, `claudecollab-opencode`). Verified: container starts, both agents run as `node`, volumes are node-writable.

## Outstanding / gotchas

- **Log in once inside the container**: `claude` → `/login`, and `opencode auth login`. State persists in the named volumes. (Host-credential mounting was tried and abandoned — on macOS the 600/root-owned secret is unreadable by the non-root `node` user.)
- Volume ownership is seeded node-owned from the image dirs (the `mkdir`+`chown` in the Dockerfile). `postCreate.sh` also chowns defensively.
- No network firewall on the container (decided against — low threat for trusted repos + frontier models). Revisit if delegating on untrusted repos.
- PAL/Zen MCP was intentionally **not** used (it needs API keys, conflicting with the subscription-only choice).

## Conventions

- Prefer a **non-Claude** model for `/consult` so the second opinion is genuinely independent.
- `/delegate` uses `--auto` (auto-approves opencode tool use) — always review the resulting diff; that's step 2 of the command.
- Commits: signing via 1Password fails non-interactively here; commit with `-c commit.gpgsign=false` if it blocks.
