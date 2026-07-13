# ClaudeCollab

Let **Claude Code** collaborate with **other LLMs** (OpenAI, GitHub Copilot's model stack, Google Gemini, or anything else) for a second opinion, multi-model consensus, or delegated coding — using **[opencode](https://opencode.ai)** as the gateway.

Claude Code stays the driver. It calls out to opencode via a few repo-local slash commands. opencode handles model access and auth, so this works off your existing **subscriptions — no API keys stored here**. Anyone who clones this repo and has opencode authenticated can use it.

## How it works

Claude Code cannot itself run a non-Anthropic model (its agent and subagents are always Claude). So instead it *shells out* to opencode, which is model-agnostic:

```
Claude Code  ──(slash command)──▶  collab/ask.sh  ──▶  opencode run  ──▶  GPT / Copilot / Gemini / …
     ▲                                                                              │
     └───────────────────  reads the other model's answer, then reasons over it  ──┘
```

- `plan` agent → read-only, safe for opinions (`/consult`, `/consensus`)
- `build` agent → can edit files in the repo (`/delegate`)

## Setup

1. **Install opencode** (once per machine):
   ```bash
   npm install -g opencode-ai        # or: brew install anomalyco/tap/opencode
   ```
2. **Authenticate opencode to your providers** (interactive, opens a browser for OAuth — this is the subscription login, no API keys):
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

Development runs in a dev container (`.devcontainer/`) with **Claude Code and opencode both preinstalled**. Your host LLM subscription credentials are bind-mounted read-only — you authenticate once on the host, and the container reuses it. No API keys are ever baked into the image.

**Before first build**, authenticate both agents *on the host* so the credential files exist to mount:
```bash
opencode auth login     # creates ~/.local/share/opencode/auth.json
# Claude Code: ~/.claude/.credentials.json already exists once you've logged in
```
Then open the folder in the container:
- **VS Code**: "Dev Containers: Reopen in Container", or
- **CLI**: `devcontainer up --workspace-folder .` (from `@devcontainers/cli`)

The `postCreate` step verifies node/claude/opencode and confirms the mounted credentials came through.

### Credential refresh caveat
The credential mounts are **read-only**, so the container cannot refresh an expired OAuth token. If in-container auth lapses (tokens expire after a few hours), either run `claude` / `opencode` on the host to refresh, or remove `,readonly` from the credential mounts in [`.devcontainer/devcontainer.json`](.devcontainer/devcontainer.json) so the container refreshes them in place.

## Usage

Run these inside Claude Code in this repo:

| Command | What it does |
|---|---|
| `/consult <question>` | Get a second opinion from another LLM on a plan or approach (read-only). Claude weighs it against its own view. |
| `/consensus <question>` | Ask 2–3 different models the same question and have Claude synthesize + break ties. |
| `/delegate <coding task>` | Hand a coding task to another model (it edits files), then Claude reviews the diff. |

Examples:
```
/consult Is an actor the right concurrency model here, or should I use a serial queue?
/consensus What's the best migration path off Core Data for this app?
/delegate Add bounds checking to the ring buffer in src/buffer.c and a test
```

### Picking the model

By default `collab/ask.sh` uses opencode's configured default model. To choose per call:
```bash
collab/ask.sh -m openai/gpt-5 "..."
collab/ask.sh -m google/gemini-2.5-pro "..."
```
Run `opencode models` to see exact provider/model ids available with your auth. To set a repo-wide default for consults, export `COLLAB_MODEL` (e.g. in your shell profile):
```bash
export COLLAB_MODEL=openai/gpt-5
```
Prefer a **non-Claude** model for consults so the second opinion is genuinely independent.

## Direct use of the wrapper

The slash commands are thin wrappers over one script you can also call yourself:
```bash
collab/ask.sh [-m provider/model] [-a plan|build] [--edit] <prompt...>
```
See the header of [`collab/ask.sh`](collab/ask.sh) for details.

## Optional: skip the permission prompts

The first time Claude Code runs `collab/ask.sh` it will ask for permission. To pre-approve, add this to `.claude/settings.json` (or your user settings):
```json
{
  "permissions": {
    "allow": [
      "Bash(bash collab/ask.sh:*)",
      "Bash(opencode models:*)",
      "Bash(git status:*)",
      "Bash(git diff:*)"
    ]
  }
}
```

## Notes & limits

- **Cost**: calls run against your opencode-authenticated subscriptions; usage counts against those plans. `opencode stats` shows token usage/cost.
- **`--auto`**: `/delegate` auto-approves opencode's tool use so it doesn't block on prompts. Always review the diff — that's step 2 of the command.
- **Not just for coding**: `/consult` and `/consensus` are great for planning and design reviews, which is often where a second model helps most.
- **Extending**: to add the richer multi-model debate/consensus tooling later, `consult-llm` (an MCP server) can use opencode as a no-API-key backend. Not required for the above.
