# ClaudeCollab

Let **Claude Code** collaborate with **other LLMs** (OpenAI, GitHub Copilot's model stack, Google Gemini, or anything else) for a second opinion, a multi-model panel, code review, or delegated coding — using **[opencode](https://opencode.ai)** as the gateway.

Claude Code stays the driver. You add ClaudeCollab to **your own project**, and Claude gains a few slash commands backed by a small local **MCP server**. opencode handles model access and auth, so this works off **whatever providers your opencode auth gives you — paid subscriptions or free tiers — with no API keys stored or managed by this tool**.

## How it works

Claude Code cannot itself run a non-Anthropic model (its agent and subagents are always Claude). So it calls a **local MCP server** — `claudecollab`, a small TypeScript stdio server registered in your project's `.mcp.json` — which fronts `opencode serve`, model-agnostic, over its HTTP API:

```
Claude Code  ──(MCP tool call)──▶  claudecollab MCP server  ──▶  opencode serve  ──▶  GPT / Copilot / Gemini / …
     ▲                                                                                       │
     └────────────────────  reads the other model's answer, then reasons over it  ───────────┘
```

ClaudeCollab adds to a project:

| What | Where |
|---|---|
| The `claudecollab` MCP server | Registered in `.mcp.json` (launched on demand as `npx -y claudecollab serve`). It exposes the tools the slash commands call: `collab_consult`, `collab_panel`, `collab_research`, `collab_delegate`, `collab_models`. |
| The slash commands | `.claude/commands/collab/*.md` — thin prompts that drive those tools. They appear as `/collab:consult`, `/collab:panel`, `/collab:workshop`, `/collab:review`, `/collab:research`, `/collab:delegate`, `/collab:collaborate`, `/collab:configure` — so they can't clash with commands you already have. |
| Three **hardened** opencode agents | `.opencode/agent/` — `collab-read` (read-only reviewer + web), `collab-build` (the `/collab:delegate` write path), `collab-research` (the `/collab:research` source-backed path). `opencode serve` enforces their permission maps. |
| The model policy + config template | `collab/models.policy` and `collab/collab.conf.example`. |
| The record | `collab/logs/` (git-ignored) — every model call, on disk and yours to read (see [The record it keeps](#the-record-it-keeps)). |

- `collab-read` → read-only **ROLE** for opinions and planning (`/collab:consult`, `/collab:panel`, `/collab:workshop`, `/collab:review`): a default-deny allowlist (`"*": deny` at opencode's permission layer) granting exactly a Claude review subagent's tools — `read` + `grep` + `glob` + `webfetch`/`websearch`; mutation and sub-agent spawning (`task`) are denied. **Not a confidentiality boundary: trusted repos only** — it can read any file including your secrets (`.env`, keys, `.aws`/`.ssh`) and reach the web, so a secret can leave to a third-party model. Verified by `collab/verify-collab-read.sh`.
- `collab-build` → can edit files for `/collab:delegate`: same allowlist construction, re-allowing only edit/write/patch/bash; everything else is denied. Because `bash` is allowed those non-mutation denies are defense-in-depth, not a guarantee — **review the diff**. Verified by `collab/verify-collab-build.sh`.
- `collab-research` → the source-backed `/collab:research` path: **same allow-set as `collab-read`** (`read` + `grep` + `glob` + web); mutation and `task` denied. Same posture — **not a confidentiality boundary, trusted repos only**. Verified by `collab/verify-collab-research.sh`.

## Requirements

- **[Node.js](https://nodejs.org)** (ships with `npm`/`npx`) — ClaudeCollab is an npm package.
- **[opencode](https://opencode.ai)** on your PATH, authenticated to at least one provider (below).
- A **git repo** for the project you install into (so you can review `/collab:delegate` diffs). Not strictly required for read-only commands.

**Your own MCP servers:** opencode supports MCP, but ClaudeCollab's hardened agents will **not** use your MCP tools — every agent is a default-deny allowlist (`"*": deny`), and that floor covers MCP tools too (verified: an agent under the floor can't even see them). To let a delegated model reach an MCP tool you must explicitly allow it in the agent def, and that is a security decision, not a convenience one.

## Install

ClaudeCollab installs *into* whatever project you want Claude Code to have these commands in. It registers the MCP server in your `.mcp.json`, copies the command docs / agent defs / policy template, records each written file's SHA-256, and upgrades or removes a file only while its bytes still match that ownership record. Files you edited are left alone.

**Primary path — `npx` (no global install):**
```bash
cd /path/to/your/project
npx claudecollab init
```

**Or the one-liner** (a thin `install.sh` bootstrap that just runs `npx claudecollab init` for you):
```bash
curl -fsSL https://raw.githubusercontent.com/bencmorrison/ClaudeCollab/main/install.sh | bash
```
This requires Node.js on PATH. It installs into the current directory; pass `-s -- --dir /path/to/project` to target another, or `-s -- --global` to `npm i -g` the CLI first. Pin a version with `-s -- --ref 1.0.0` (or `CLAUDECOLLAB_REF=1.0.0`).

Both paths do the same thing — the bootstrap is only there so the classic `curl | bash` habit keeps working; `npx claudecollab init` is the honest, direct form.

Then authenticate opencode and verify:
```bash
opencode auth login          # interactive OAuth — your provider login (subscription or free tier), no API keys
npx claudecollab doctor      # token-free check of the whole setup
```
Repeat `opencode auth login` for each provider you want (OpenAI / ChatGPT, GitHub Copilot, Google Gemini, …). **Restart Claude Code** after installing so it picks up the new MCP server.

### Updating

Re-run the same command — `npx claudecollab init` is idempotent. It upgrades files you haven't touched (bytes still matching the recorded hash), leaves any file you edited locally alone, and adds new payload files. To move to a specific release, `npx claudecollab@1.0.0 init`. There is no separate update mode.

## Usage

Run these inside Claude Code in a project you've installed into:

| Command | What it does |
|---|---|
| `/collab:consult <question>` | Get a second opinion from another LLM on a plan or approach (read-only). Claude weighs it against its own view. |
| `/collab:panel <question>` | Ask 2–3 different models the same question and have Claude synthesize + break ties. Warns if the panel isn't cross-provider. |
| `/collab:workshop <goal>` | A **multi-LLM planning session**: 2–3 models write independent plans, Claude synthesizes, then those same models **critique Claude's synthesis** before Claude dispositions each point into a final plan. ~2 calls per model. |
| `/collab:review <target>` | Findings-first code review by another model, then Claude verifies each finding against the code before reporting. Target a path, the diff, or a branch. |
| `/collab:research <question>` | Source-backed investigation by a **web-capable** model, then Claude fetches the cited sources and verifies each claim before reporting. Fabricated citations get refuted, not repeated. |
| `/collab:delegate <coding task>` | Hand a coding task to another model (it edits files), then Claude reviews the diff. |
| `/collab:collaborate <question>` | Bounded multi-turn peer exchange with another model; Claude dispositions each point (read-only). |
| `/collab:configure` | Interactive setup: writes your model policy and preferred-model defaults to git-ignored config files. |

Examples:
```
/collab:consult Is an actor the right concurrency model here, or should I use a serial queue?
/collab:panel What's the best migration path off Core Data for this app?
/collab:review the uncommitted diff
/collab:delegate Add bounds checking to the ring buffer in src/buffer.c and a test
```

### Picking the model

To see the exact provider/model ids your auth offers, ask Claude to run the `collab_models` tool (or run `opencode models` yourself). Pass a specific model to any command; omit it to use your configured default.

To set **persistent defaults** — a default single model for `/collab:consult` and a default panel set for `/collab:panel` — run **`/collab:configure`** (it walks you through it), or copy `collab/collab.conf.example` to `collab/collab.conf.local` (git-ignored) and set:
```
COLLAB_MODEL=openai/gpt-5
COLLAB_MODELS=openai/gpt-5 google/gemini-2.5-pro
```
These take effect immediately — no restart. (The matching env vars still work as one-off overrides; precedence is arg → env → config file → opencode's default.) Prefer a **non-Claude** model for consults so the second opinion is genuinely independent.

## Safety

ClaudeCollab has real, verifiable guardrails — but it is **not a sandbox**. Use it on trusted repositories. See **[SECURITY.md](SECURITY.md)** for the full threat model; the essentials:

- **Read-only commands (`/collab:consult`, `/collab:panel`, `/collab:workshop`, `/collab:review`, `/collab:collaborate`)** run under a default-deny allowlist agent with a review subagent's tools — read, grep/glob, and the web; it cannot mutate, shell out, or spawn subagents. It is **not a confidentiality boundary**: it can read any repo file **including your secrets** and reach the network, so a secret can leave to a third-party model. **Trusted repos only.** Proven by `collab/verify-collab-read.sh`.
- **`/collab:research` is the source-backed web path.** Same read + web exposure and same "trusted repos only" posture; its value is the workflow requiring citations and Claude verification. Proven by `collab/verify-collab-research.sh`.
- **`/collab:delegate` can edit files and run shell.** Its non-mutation restrictions are defense-in-depth, not a guarantee (a coding task needs `bash`, and `bash` can reach around them), so **the trust boundary is you reviewing the diff.** The tool snapshots the worktree first and records the model's patch separately, so dirty worktrees are allowed.
- **External model output is treated as data, not instructions** — a consulted model can't smuggle commands into Claude's control flow.
- Run `npx claudecollab doctor` to check your setup before relying on any of this.

## The record it keeps

Every model call is logged to `collab/logs/<run_id>/calls.jsonl` as three lifecycle entries sharing one `call_id`: `expected-call` before capture setup, `started` before execution, and `completed` after it. Three calls produce nine lifecycle entries. The record includes the exact prompt sent, the model's full untruncated answer, model, agent, and exit status. It's git-ignored and stays on your machine.

This is **receipts**. When Claude tells you "GPT-5 agreed with my approach", that summary is written by the party you'd be checking up on — the log is the other model's *actual words*, on disk and yours to read, so you can check them yourself, diff them against Claude's account, or keep them for later. It's a plain local file, governed by the privacy knobs below. It earned its keep finding real bugs during this project's own development.

- **See it:** `cat collab/logs/latest/calls.jsonl | jq`. Verification (built into the server's evidence layer) checks lifecycle cardinality in both directions, capture completeness, referenced artifacts, every entry's self-hash, and the chain; setup failures and mid-flight gaps do not pass as clean.
- **Privacy:** by default the log keeps the full prompt, which means whatever context Claude pasted in from your repo. Set `COLLAB_LOG_PROMPTS=hash` (keep a digest, not the text) or `off` in `collab/collab.conf.local` if that's not OK for your work. Runs older than 14 days are pruned automatically (`COLLAB_LOG_RETENTION_DAYS`); `COLLAB_LOG=off` turns the whole thing off.
- **What it is not:** tamper-proofing. The hashes catch accidental corruption; they're not a chain of custody, and anything that can write the log can rewrite them.

## Uninstall

```bash
npx claudecollab init --uninstall        # in the project you installed into (or --dir <path>)
```
It removes only the files ClaudeCollab installed and can still prove it owns (by hash), and removes its `.mcp.json` key; your own files, config, and `collab/logs/` are left in place. Any Claude Code permission grant you added to `.claude/settings*.json` is yours to remove.

## Skip the permission prompts

The first time Claude Code calls a ClaudeCollab MCP tool it asks for permission. Choosing "yes, and don't ask again" persists that tool (e.g. `mcp__claudecollab__collab_consult`) into your project's `.claude/settings.local.json` (git-ignored) — per tool, per project, across sessions. Worst case is a handful of one-time prompts. To pre-approve them all up front, add the tool names to `.claude/settings.local.json`:
```json
{
  "permissions": {
    "allow": [
      "mcp__claudecollab__collab_consult",
      "mcp__claudecollab__collab_panel",
      "mcp__claudecollab__collab_research",
      "mcp__claudecollab__collab_delegate",
      "mcp__claudecollab__collab_models"
    ]
  }
}
```

## Notes & limits

- **Cost**: calls run against your opencode-authenticated providers; usage counts against those plans (free tiers included). `opencode stats` shows token usage/cost.
- **Not just for coding**: `/collab:consult` and `/collab:panel` are great for planning and design reviews, which is often where a second model helps most.
- **Always review `/collab:delegate` diffs** — that human review is the trust boundary for the write path.

## Bugs & feedback

Found a bug, hit a rough edge, or want to suggest something? Please open a **[GitHub issue](https://github.com/bencmorrison/ClaudeCollab/issues)**.

What helps most in a bug report:
- The output of `npx claudecollab doctor`.
- Which command you ran, and the model it used.
- Your OS. macOS and BSD support is newer and less exercised than Linux, so please say if you're on one.

**Security issues are the exception — do not open a public issue for them.** Report those privately via the [Security tab](https://github.com/bencmorrison/ClaudeCollab/security), as described in **[SECURITY.md](SECURITY.md)**. That file also documents what this tool deliberately does *not* guarantee: the read-only agents reach the web by design and can read your secrets, and `/collab:delegate` allows `bash`, so neither is an exfiltration boundary.

## Working on ClaudeCollab itself

Contributing to ClaudeCollab (not just using it)? The repo ships a dev container that runs Claude Code and opencode in-container with persistent auth, plus the full TypeScript test suite (`npm test`) and the shell lint/verify scripts. See **[CONTRIBUTING.md](CONTRIBUTING.md)** and **[AGENTS.md](AGENTS.md)**.
