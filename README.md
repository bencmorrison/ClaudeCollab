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

## Setup

Exactly what you do, start to finish. It's five steps: **(1)** prerequisites, **(2)** register the MCP server in your project, **(3)** restart Claude Code so it loads it, **(4)** verify, **(5)** configure which models it uses. Steps 2 and 5 are **different things** and easy to conflate — step 2 *registers the server* (writes `.mcp.json`); step 5 *configures its behavior* (which models, which policy). You want both.

> **Read this first — the package is not on npm yet.** The intended install is `npx claudecollab init`, but ClaudeCollab **hasn't been published to npm** (0.5.0 isn't out). Until it is, `npx claudecollab …` fails with "package not found". **Today you build it locally and register with `--abs`** — that's step 2a below, and it's fully supported (not a hack). The published `npx` path (step 2b) is documented so it's ready when 0.5.0 ships; it will not work before then.

### 1. Prerequisites

- **[Node.js](https://nodejs.org)** (ships with `npm`/`npx`) — ClaudeCollab is a TypeScript CLI + MCP server; you need Node to build and run it.
- **[opencode](https://opencode.ai)** on your PATH, **authenticated to at least one provider**. The MCP server fronts `opencode serve`, so this is what gives Claude access to other models:
  ```bash
  opencode auth login     # interactive OAuth — subscription or free tier, no API keys stored by this tool
  ```
  Repeat it for each provider you want (OpenAI / ChatGPT, GitHub Copilot, Google Gemini, …). `opencode models` lists what your auth actually offers.
- **[Claude Code](https://claude.com/claude-code)** — the driver. ClaudeCollab is loaded by Claude Code as a project MCP server.
- A **git repo** for the project you install into, so you can review `/collab:delegate` diffs. Not strictly required for the read-only commands.

**Your own MCP servers:** opencode supports MCP, but ClaudeCollab's hardened agents will **not** use your MCP tools — every agent is a default-deny allowlist (`"*": deny`), and that floor covers MCP tools too (verified: an agent under the floor can't even see them). To let a delegated model reach an MCP tool you must explicitly allow it in the agent def, and that is a security decision, not a convenience one.

### 2. Register the MCP server in your project

This is the step that makes the `/collab:*` commands exist. `init` registers the `claudecollab` server in your project's `.mcp.json`, copies the command docs / agent defs / policy template, records each written file's SHA-256, and upgrades or removes a file only while its bytes still match that ownership record — files you edited are left alone.

#### 2a. Now (works today) — build locally, register with `--abs`

Clone and build the CLI once:
```bash
git clone https://github.com/bencmorrison/ClaudeCollab.git
cd ClaudeCollab
npm install && npm run build      # produces dist/cli.js
```
Then, from the CLI checkout, register it into **your** project. `--abs` writes an absolute local launch line instead of the (unpublished) `npx` one:
```bash
node dist/cli.js init --abs --dir /path/to/your/project
```
(Or `cd /path/to/your/project` first and run `node /path/to/ClaudeCollab/dist/cli.js init --abs` — `--dir` defaults to the current directory.)

That writes a `claudecollab` block into your project's `.mcp.json`:
```json
{
  "mcpServers": {
    "claudecollab": {
      "command": "node",
      "args": ["/path/to/ClaudeCollab/dist/cli.js", "serve"],
      "env": { "COLLAB_PROJECT_DIR": "/path/to/your/project" }
    }
  }
}
```
The paths are absolute and machine-specific — that's the point of `--abs`: no registry resolution, guaranteed runnable. If you move or delete the ClaudeCollab checkout, re-run `init --abs` (or hand-edit the paths). **Hand-written alternative:** if you'd rather not run `init`, you can paste the block above into `.mcp.json` yourself (fixing the two paths) for the same effect — but then you don't get the command docs, agent defs, or policy template, which `init` also places. Prefer `init`.

#### 2b. Once 0.5.0 is published (the intended path — not available yet)

When the package is on npm, this replaces all of 2a:
```bash
cd /path/to/your/project
npx claudecollab init            # writes the published `npx -y claudecollab serve` launch line
```
Or the one-liner bootstrap (a thin `install.sh` that runs `npx claudecollab init` for you, for the classic `curl | bash` habit):
```bash
curl -fsSL https://raw.githubusercontent.com/bencmorrison/ClaudeCollab/main/install.sh | bash
```
The bootstrap installs into the current directory; pass `-s -- --dir /path/to/project` to target another. Pin a version with `-s -- --ref 0.5.0` (or `CLAUDECOLLAB_REF=0.5.0`). **Both of these require the package to be on npm and will fail until 0.5.0 ships.**

### 3. Restart Claude Code

Claude Code reads a project-root `.mcp.json` **at session start**, so it will not see the server you just registered until you restart it in that project. Quit and reopen Claude Code (or start a fresh session) in `/path/to/your/project`.

### 4. Verify

Run the token-free `doctor` — it checks opencode is present, the `.mcp.json` registration, the agent defs, and the policy, without calling any model:
```bash
node /path/to/ClaudeCollab/dist/cli.js doctor --dir /path/to/your/project   # local build (today)
# npx claudecollab doctor                                                   # once published
```
A healthy result looks like:
```
✓ MCP server registered in .mcp.json under key 'claudecollab'
✓ 8/8 command docs present in .claude/commands/collab/
✓ 3/3 hardened agent defs present in .opencode/agent/
✓ model policy present (collab/models.policy)
✓ opencode present (…)

doctor: OK
```
Inside the restarted Claude Code, the `/collab:*` commands now appear in the slash-command list and the `collab_*` MCP tools are available. **The first time** Claude Code calls one, it asks a one-time permission for that tool (e.g. `mcp__claudecollab__collab_consult`) — approve it (see [Skip the permission prompts](#skip-the-permission-prompts) to pre-approve them all).

### 5. Configure which models it uses

Registering the server (step 2) does not choose *which* models it talks to or what your policy allows — that's this step, and it's separate. Two ways, both effective immediately (no restart):

- **Interactive:** run **`/collab:configure`** inside Claude Code. It interviews you and writes your model policy (deny/ask/allow) and preferred-model defaults to the git-ignored config files.
- **By hand:** edit the two git-ignored files under `collab/`:
  - `collab/models.policy.local` — per-model `deny`/`ask`/`allow` rules (the committed `collab/models.policy` is default-allow).
  - `collab/collab.conf.local` (copy from `collab/collab.conf.example`) — your default single model and panel set:
    ```
    COLLAB_MODEL=openai/gpt-5
    COLLAB_MODELS=openai/gpt-5 google/gemini-2.5-pro
    ```

Prefer a **non-Claude** model for consults so the second opinion is genuinely independent. This step is optional — without it, commands use opencode's default model — but setting a policy and defaults is what makes day-to-day use smooth.

### Updating

Re-run `init` (locally: `node dist/cli.js init --abs --dir <project>`; once published: `npx claudecollab init`). It's idempotent: it upgrades files you haven't touched (bytes still matching the recorded hash), leaves any file you edited locally alone, and adds new payload files. After a local rebuild (`npm run build`), re-running `init` refreshes the project's payload. There is no separate update mode.

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

## Troubleshooting

- **`npx claudecollab …` says "package not found".** Expected — it isn't published to npm yet. Use the local build path: `npm run build` in the ClaudeCollab checkout, then `node dist/cli.js init --abs --dir <project>` (see [Setup step 2a](#2a-now-works-today--build-locally-register-with---abs)).
- **The `/collab:*` commands don't appear in Claude Code.** Restart Claude Code — it only reads `.mcp.json` at session start (Setup step 3). Still missing? Confirm your project's `.mcp.json` has a `claudecollab` key under `mcpServers`, and run `doctor` (step 4) to check registration and payload.
- **A `collab_*` tool call errors about opencode.** opencode isn't installed on PATH or isn't authenticated. Run `opencode auth login`, and `opencode models` to confirm at least one provider answers. If you built locally and moved the checkout, the `.mcp.json` `args` path is stale — re-run `init --abs`.
- **A model is denied / not allowed.** That's the model policy. Run `/collab:configure`, or edit `collab/models.policy.local` (Setup step 5).
- **Not sure what's wrong.** Run `doctor` — it reports each check with `✓`/`✗` and needs no model call.

## Safety

ClaudeCollab has real, verifiable guardrails — but it is **not a sandbox**. Use it on trusted repositories. See **[SECURITY.md](SECURITY.md)** for the full threat model; the essentials:

- **Read-only commands (`/collab:consult`, `/collab:panel`, `/collab:workshop`, `/collab:review`, `/collab:collaborate`)** run under a default-deny allowlist agent with a review subagent's tools — read, grep/glob, and the web; it cannot mutate, shell out, or spawn subagents. It is **not a confidentiality boundary**: it can read any repo file **including your secrets** and reach the network, so a secret can leave to a third-party model. **Trusted repos only.** Proven by `collab/verify-collab-read.sh`.
- **`/collab:research` is the source-backed web path.** Same read + web exposure and same "trusted repos only" posture; its value is the workflow requiring citations and Claude verification. Proven by `collab/verify-collab-research.sh`.
- **`/collab:delegate` can edit files and run shell.** Its non-mutation restrictions are defense-in-depth, not a guarantee (a coding task needs `bash`, and `bash` can reach around them), so **the trust boundary is you reviewing the diff.** The tool snapshots the worktree first and records the model's patch separately, so dirty worktrees are allowed.
- **External model output is treated as data, not instructions** — a consulted model can't smuggle commands into Claude's control flow.
- Run `doctor` (step 4 of [Setup](#setup)) to check your setup before relying on any of this.

## The record it keeps

Every model call is logged to `collab/logs/<run_id>/calls.jsonl` as three lifecycle entries sharing one `call_id`: `expected-call` before capture setup, `started` before execution, and `completed` after it. Three calls produce nine lifecycle entries. The record includes the exact prompt sent, the model's full untruncated answer, model, agent, and exit status. It's git-ignored and stays on your machine.

This is **receipts**. When Claude tells you "GPT-5 agreed with my approach", that summary is written by the party you'd be checking up on — the log is the other model's *actual words*, on disk and yours to read, so you can check them yourself, diff them against Claude's account, or keep them for later. It's a plain local file, governed by the privacy knobs below. It earned its keep finding real bugs during this project's own development.

- **See it:** `cat collab/logs/latest/calls.jsonl | jq`. Verification (built into the server's evidence layer) checks lifecycle cardinality in both directions, capture completeness, referenced artifacts, every entry's self-hash, and the chain; setup failures and mid-flight gaps do not pass as clean.
- **Privacy:** by default the log keeps the full prompt, which means whatever context Claude pasted in from your repo. Set `COLLAB_LOG_PROMPTS=hash` (keep a digest, not the text) or `off` in `collab/collab.conf.local` if that's not OK for your work. Runs older than 14 days are pruned automatically (`COLLAB_LOG_RETENTION_DAYS`); `COLLAB_LOG=off` turns the whole thing off.
- **What it is not:** tamper-proofing. The hashes catch accidental corruption; they're not a chain of custody, and anything that can write the log can rewrite them.

## Uninstall

```bash
node /path/to/ClaudeCollab/dist/cli.js init --uninstall --dir /path/to/your/project   # local build (today)
# npx claudecollab init --uninstall --dir /path/to/your/project                        # once published
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
- The output of `doctor` (`node <repo>/dist/cli.js doctor` for a local build, or `npx claudecollab doctor` once published).
- Which command you ran, and the model it used.
- Your OS. macOS and BSD support is newer and less exercised than Linux, so please say if you're on one.

**Security issues are the exception — do not open a public issue for them.** Report those privately via the [Security tab](https://github.com/bencmorrison/ClaudeCollab/security), as described in **[SECURITY.md](SECURITY.md)**. That file also documents what this tool deliberately does *not* guarantee: the read-only agents reach the web by design and can read your secrets, and `/collab:delegate` allows `bash`, so neither is an exfiltration boundary.

## Working on ClaudeCollab itself

Contributing to ClaudeCollab (not just using it)? The repo ships a dev container that runs Claude Code and opencode in-container with persistent auth, plus the full TypeScript test suite (`npm test`) and the shell lint/verify scripts. See **[CONTRIBUTING.md](CONTRIBUTING.md)** and **[AGENTS.md](AGENTS.md)**.
