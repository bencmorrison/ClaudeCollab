# ClaudeCollab — agent guide

Lets **Claude Code** collaborate with **other LLMs** (OpenAI, GitHub Copilot, Google Gemini, …) via **[opencode](https://opencode.ai)** as an auth gateway — no API keys stored or managed by this repo. See [README.md](README.md) for full setup and usage, and [PLAN.md](PLAN.md) for the roadmap toward an OSS release (read it before large changes — several current behaviors are slated to change).

> **This file is read by every agent that works here.** `CLAUDE.md` is a symlink to it (Claude Code reads `CLAUDE.md`), and opencode reads `AGENTS.md` natively — so both the driver and any delegated model share one source of truth.
>
> **Keep it current.** Treat this as living documentation: update it whenever you change a command, the wrapper, the dev container, or a convention — in the *same* change, not "later". A stale guide misleads the next agent. When you finish a task that changes how the repo works, ask yourself "does AGENTS.md still describe reality?" and edit it if not.

## Architecture

Claude Code cannot run a non-Anthropic model itself, so it *shells out* to opencode:

```
Claude Code ──(slash command)──▶ collab/ask.sh ──▶ opencode run ──▶ GPT / Copilot / Gemini / …
     ▲                                                                          │
     └──────────────── reads the other model's answer, then reasons over it ────┘
```

- **`collab/ask.sh`** — the single entry point. Wraps `opencode run --agent <plan|build> --auto [-m provider/model] <prompt>`. Also supports `-s/--session <id>` (continue an opencode session) and `--emit-session` (print `SESSION: <id>` + the extracted answer, for `/collaborate`'s multi-turn Option B). Run `bash collab/ask.sh -h` for its interface. **Note:** it redirects opencode's stdin from `/dev/null` — load-bearing, see Gotchas.
  - `plan` agent = read-only *by opencode's plan-mode enforcement + model compliance* — **not** a hard sandbox. It does not deny `bash`, so the guarantee is behavioral, not construction. Owning our own `collab-read` agent that denies shell/write is a [PLAN.md](PLAN.md) Phase 1 item. Treat "read-only" as "should not mutate," not "cannot."
  - `build` agent = **can edit files** in this repo (used by `--edit`).
- **`.claude/commands/`** — the slash commands, all thin wrappers over `ask.sh`:
  - `/consult <q>` — one second opinion, read-only. Claude weighs it against its own view.
  - `/consensus <q>` — ask 2–3 models from different families, synthesize, break ties.
  - `/delegate <task>` — another model edits files (`--edit`), then Claude reviews the diff.
  - `/collaborate <q>` — bounded multi-turn *peer* exchange (read-only). Uses session continuation so opencode carries the other model's turns and Claude never re-transmits its words; Claude must disposition each point (Adopt/Adapt/Reject/Defer), not just collect an opinion. See PLAN.md "Option B" decision.

## Dev container & auth

- `.devcontainer/` runs Claude Code **and** opencode in-container, both on PATH for the `node` user.
- Auth is **in-container login**, persisted across rebuilds via named volumes (`claudecollab-claude`, `claudecollab-opencode`). Log in once: `claude` → `/login`, and `opencode auth login`.
- Host-credential mounting was tried and **abandoned** — on macOS the mode-600/root-owned secret is unreadable by the non-root `node` user through the mount.
- Volume ownership is seeded node-owned via the `mkdir`+`chown` in the `Dockerfile`; `postCreate.sh` also chowns defensively and reports login status on each create.
- **`gh` CLI** is installed via a dev-container Feature; its auth persists in the `claudecollab-gh` volume (`gh auth login` once).
- **Host config import:** the host `~/.claude` and `~/.dotfiles` are mounted read-only; `postCreate.sh` links your global `CLAUDE.md`, `statusline-command.sh`, and (if present) `commands`/`agents` into the active `~/.claude`, and activates `settings.json` on a fresh volume. Config only — never host credentials.
- **Login persistence gotcha:** Claude Code splits state between `~/.claude/` (the volume, persists) and `~/.claude.json` (in `$HOME`, on the ephemeral FS — would be wiped each rebuild, forcing re-login). `postCreate.sh` keeps the real file in the volume (`home-dot-claude.json`) and symlinks `~/.claude.json` to it.

## Conventions

- **Model choice depends on Claude's role.** When Claude is *authoring* the work (collaborating with you directly), prefer a **non-Claude** model for `/consult`/`/panel` so the outside view is genuinely independent — Claude already brings the Anthropic perspective. When Claude is purely *coordinating* (handing the work to other agents and only synthesizing), an **Anthropic model is eligible** in the panel too, since its own reasoning isn't the deliverable. Anthropic is never denied by default. Set a repo-wide default with `export COLLAB_MODEL=provider/model`.
- `/delegate` uses `--auto` (auto-approves opencode's tool use so it doesn't block). **Always review the resulting diff** with `git status` / `git diff` — that's step 2 of the command, not optional.
- When delegating, keep your own edits distinct from the delegated model's in your summary.
- Commits are **signed** (SSH signing backed by the 1Password agent, which VS Code forwards into the container; git is preconfigured with `gpg.format=ssh` + `commit.gpgsign=true`, using the "GitHub Signing Key"). A commit fires a **1Password approval prompt on the host** — approve it. Only when running truly headless (no host to approve) fall back to `git -c commit.gpgsign=false commit …`.

## Gotchas / decisions

- **`ask.sh` redirects opencode's stdin from `/dev/null` — this is load-bearing, do not remove it.** `opencode run` blocks waiting on stdin when stdin is a non-TTY pipe (exactly what Claude Code's Bash tool hands the wrapper), so without the redirect every Claude-invoked call hangs until killed. Interactive TTYs don't hit this, which is why it only bites when Claude drives it. The optional `$COLLAB_TIMEOUT` (off by default) is just a backstop; the redirect is the actual fix. (Diagnosed the hard way 2026-07-15 — see PLAN.md "Transport note".)
- No network firewall on the container (decided against — low threat for trusted repos + frontier models). Revisit if delegating on untrusted repos.
- PAL/Zen-style MCP servers were intentionally **not** used — they need API keys, conflicting with the subscription-only design.
- opencode's `run` supports `-m/--model`, `--agent`, and `--auto` (verified on opencode 1.17.20). If you bump opencode and these flags change, update `ask.sh` and this file together.

## Repo health notes

- This is a normal git repo on branch `main`. (If git ever reports "not a repository" but `.git/` exists, check that `.git/HEAD` is present — it should contain `ref: refs/heads/main`.)
