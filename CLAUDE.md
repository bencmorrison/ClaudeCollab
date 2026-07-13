# ClaudeCollab — project context

Lets **Claude Code** collaborate with **other LLMs** (OpenAI, GitHub Copilot, Google Gemini) via **opencode** as a subscription-auth gateway — no API keys. See [README.md](README.md) for full usage.

## Current state (as of setup)

- Slash commands live in `.claude/commands/`: `/consult` (second opinion, read-only), `/consensus` (multi-model synthesis), `/delegate` (hand a coding task to another model, then review its diff).
- All three shell out to `collab/ask.sh`, a wrapper over `opencode run` (`plan` agent = read-only, `build` agent = edits files).
- Dev container (`.devcontainer/`) runs Claude Code **and** opencode in-container. Host subscription credentials are bind-mounted **read-only**. Image build is verified.

## Outstanding / gotchas

- **opencode must be authed on the host** (`opencode auth login`) before the container is built — the mount points at `~/.local/share/opencode/auth.json`, which only exists after login.
- **Read-only credential mounts can't refresh expired OAuth tokens.** If in-container auth lapses, re-auth on the host or drop `,readonly` from the credential mounts in `.devcontainer/devcontainer.json`.
- No network firewall on the container (decided against — low threat for trusted repos + frontier models). Revisit if delegating on untrusted repos.
- PAL/Zen MCP was intentionally **not** used (it needs API keys, conflicting with the subscription-only choice).

## Conventions

- Prefer a **non-Claude** model for `/consult` so the second opinion is genuinely independent.
- `/delegate` uses `--auto` (auto-approves opencode tool use) — always review the resulting diff; that's step 2 of the command.
- Commits: signing via 1Password fails non-interactively here; commit with `-c commit.gpgsign=false` if it blocks.
