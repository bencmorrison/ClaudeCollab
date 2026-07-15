# ClaudeCollab

Let **Claude Code** collaborate with **other LLMs** (OpenAI, GitHub Copilot's model stack, Google Gemini, or anything else) for a second opinion, a multi-model panel, or delegated coding — using **[opencode](https://opencode.ai)** as the gateway.

Claude Code stays the driver. It calls out to opencode via a few repo-local slash commands. opencode handles model access and auth, so this works off **whatever providers your opencode auth gives you — paid subscriptions or free tiers — with no API keys stored or managed by this repo**. Anyone who clones this repo and has opencode authenticated can use it.

## How it works

Claude Code cannot itself run a non-Anthropic model (its agent and subagents are always Claude). So instead it *shells out* to opencode, which is model-agnostic:

```
Claude Code  ──(slash command)──▶  collab/ask.sh  ──▶  opencode run  ──▶  GPT / Copilot / Gemini / …
     ▲                                                                              │
     └───────────────────  reads the other model's answer, then reasons over it  ──┘
```

- `collab-read` agent → read-only **by construction** for opinions (`/consult`, `/panel`): a default-deny allowlist (`"*": deny` at opencode's permission layer) that grants **only** reading non-secret files — all mutation, content search/glob, sub-agent spawning, network egress, and secret reads are denied. Verified by `collab/verify-collab-read.sh`. (Falls back to opencode's weaker compliance-only `plan` agent if the def is missing.)
- `collab-build` agent → can edit files in the repo for `/delegate`: same allowlist construction, re-allowing only edit/write/patch/bash; everything else (sub-agents, grep/glob, network, secret reads) is denied. Because `bash` is allowed those non-mutation denies are defense-in-depth, not a guarantee — **review the diff**. Verified by `collab/verify-collab-build.sh`. Falls back to opencode's unrestricted `build` agent if the def is missing.

## Setup

1. **Install opencode** (once per machine):
   ```bash
   npm install -g opencode-ai        # or: brew install anomalyco/tap/opencode
   ```
2. **Authenticate opencode to your providers** (interactive, opens a browser for OAuth — your provider login, subscription or free tier, no API keys):
   ```bash
   opencode auth login
   ```
   Repeat for each provider you want (OpenAI / ChatGPT, GitHub Copilot, Google Gemini, …).
3. **Verify** you can see models:
   ```bash
   opencode models
   ```

That's it. The slash commands below are already in `.claude/commands/`.

## Dev container (recommended)

Development runs in a dev container (`.devcontainer/`) with **Claude Code and opencode both preinstalled**. You log in **once inside the container**; login state persists across rebuilds in named volumes (`claudecollab-claude`, `claudecollab-opencode`). No API keys or host credentials are baked into the image.

> Why in-container login and not host-credential mounts? On macOS, the host credential files are mode `600` and appear `root`-owned through Docker's mount layer, so the non-root `node` user the agents run as can't read them. In-container login sidesteps that and lets the agents refresh their own tokens.

1. Open the folder in the container:
   - **VS Code**: "Dev Containers: Reopen in Container", or
   - **CLI**: `devcontainer up --workspace-folder .` (from `@devcontainers/cli`)
2. Inside the container, log in once:
   ```bash
   claude               # then type: /login   (device-code OAuth in your browser)
   opencode auth login  # pick OpenAI / Copilot / Gemini
   ```
3. Verify:
   ```bash
   opencode models
   ```

The `postCreate` step reports login status each time. Because state lives in the named volumes, you only log in again if you delete those volumes.

## Usage

Run these inside Claude Code in this repo:

| Command | What it does |
|---|---|
| `/consult <question>` | Get a second opinion from another LLM on a plan or approach (read-only). Claude weighs it against its own view. |
| `/panel <question>` | Ask 2–3 different models the same question and have Claude synthesize + break ties. Warns if the panel isn't cross-provider. |
| `/review <target>` | Findings-first code review by another model, then Claude verifies each finding against the code before reporting. Target a path, the diff, or a branch. |
| `/delegate <coding task>` | Hand a coding task to another model (it edits files), then Claude reviews the diff. |

Examples:
```
/consult Is an actor the right concurrency model here, or should I use a serial queue?
/panel What's the best migration path off Core Data for this app?
/review the uncommitted diff
/delegate Add bounds checking to the ring buffer in src/buffer.c and a test
```

### Picking the model

By default `collab/ask.sh` uses opencode's configured default model. To choose per call:
```bash
collab/ask.sh -m openai/gpt-5 "..."
collab/ask.sh -m google/gemini-2.5-pro "..."
```
Run `opencode models` to see the exact provider/model ids available with your auth.

To set **persistent defaults** — a default single model for `/consult` and a default panel set for `/panel` — run **`/configure-collab`** (it walks you through it), or copy `collab/collab.conf.example` to `collab/collab.conf.local` (git-ignored) and set:
```
COLLAB_MODEL=openai/gpt-5
COLLAB_MODELS=openai/gpt-5 google/gemini-2.5-pro
```
These take effect immediately — no shell reload. (Env vars `COLLAB_MODEL`/`COLLAB_MODELS` still work as one-off overrides; precedence is `-m` flag / args → env → config file → opencode's default.) Prefer a **non-Claude** model for consults so the second opinion is genuinely independent.

## Direct use of the wrapper

The slash commands are thin wrappers over one script you can also call yourself:
```bash
collab/ask.sh [-m provider/model] [-a collab-read|collab-build|plan|build] [--edit] [--allow-dirty] <prompt...>
```
See the header of [`collab/ask.sh`](collab/ask.sh) (or `bash collab/ask.sh -h`) for the full interface.

## Safety

ClaudeCollab has real, verifiable guardrails — but it is **not a sandbox**. Use it on trusted repositories. See **[SECURITY.md](SECURITY.md)** for the full threat model; the essentials:

- **Read-only commands (`/consult`, `/panel`, `/review`, `/collaborate`)** run under a default-deny allowlist agent that can *only* read non-secret files — no mutation, no content search, no network — enforced at opencode's permission layer, not by asking the model nicely. Proven by `collab/verify-collab-read.sh`.
- **`/delegate` can edit files and run shell.** Its non-mutation restrictions are defense-in-depth, not a guarantee (a coding task needs `bash`, and `bash` can reach around them), so **the trust boundary is you reviewing the diff.** The wrapper refuses to delegate on a dirty worktree and prints the pre-edit `HEAD` so the diff is exactly the model's work.
- **External model output is treated as data, not instructions** — a consulted model can't smuggle commands into Claude's control flow.
- Run `bash collab/doctor.sh` to check your setup before relying on any of this.

## Optional: skip the permission prompts

The first time Claude Code runs `collab/ask.sh` it will ask for permission. To pre-approve, add this to `.claude/settings.json` (or your local `.claude/settings.local.json`, which is git-ignored):
```json
{
  "permissions": {
    "allow": [
      "Bash(bash collab/ask.sh:*)",
      "Bash(COLLAB_CONFIRMED=1 bash collab/ask.sh:*)",
      "Bash(bash collab/panel-models.sh:*)",
      "Bash(bash collab/doctor.sh:*)",
      "Bash(opencode models:*)",
      "Bash(git status:*)",
      "Bash(git diff:*)",
      "Bash(git log:*)"
    ]
  }
}
```

## Notes & limits

- **Cost**: calls run against your opencode-authenticated providers; usage counts against those plans (free tiers included). `opencode stats` shows token usage/cost.
- **`--auto`**: `/delegate` auto-approves opencode's tool use so it doesn't block on prompts. Always review the diff — that's step 2 of the command.
- **Not just for coding**: `/consult` and `/panel` are great for planning and design reviews, which is often where a second model helps most.
- **Extending**: to add the richer multi-model debate/consensus tooling later, `consult-llm` (an MCP server) can use opencode as a no-API-key backend. Not required for the above.
