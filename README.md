# ModelGuild

Let **Claude Code** collaborate with **other LLMs** (OpenAI, GitHub Copilot's model stack, Google Gemini, or anything else) for a second opinion, a multi-model panel, code review, or delegated coding — using **[opencode](https://opencode.ai)** as the gateway.

Works in any stdio MCP client. **Claude Code is the first-class — and currently the only — driver** (slash commands + the verify-each-finding workflow); support for other drivers is planned.

Claude Code stays the driver. You add ModelGuild to **your own project**, and Claude gains a few slash commands backed by a small local **MCP server**. opencode handles model access and auth, so this works off **whatever providers your opencode auth gives you — paid subscriptions or free tiers — with no API keys stored or managed by this tool**.

## How it works

Claude Code cannot itself run a non-Anthropic model (its agent and subagents are always Claude). So it calls a **local MCP server** — `modelguild`, a small TypeScript stdio server you register with Claude Code (per-project or global, your choice) — which fronts `opencode serve`, model-agnostic, over its HTTP API:

```
Claude Code  ──(MCP tool call)──▶  modelguild MCP server  ──▶  opencode serve  ──▶  GPT / Copilot / Gemini / …
     ▲                                                                                       │
     └────────────────────  reads the other model's answer, then reasons over it  ───────────┘
```

ModelGuild adds to a project:

| What | Where |
|---|---|
| The `modelguild` MCP server | Registered with Claude Code by you (`claude mcp add`, launched on demand as `npx -y modelguild serve`). It exposes the tools the slash commands call: `guild_consult`, `guild_panel`, `guild_research`, `guild_delegate`, `guild_models`. |
| The slash commands | `.claude/commands/guild/*.md` — thin prompts that drive those tools. They appear as `/guild:consult`, `/guild:panel`, `/guild:workshop`, `/guild:review`, `/guild:research`, `/guild:delegate`, `/guild:collaborate`, `/guild:configure` — so they can't clash with commands you already have. |
| Three **hardened** opencode agents | `.opencode/agent/` — `guild-read` (read-only reviewer + web), `guild-build` (the `/guild:delegate` write path), `guild-research` (the `/guild:research` source-backed path). `opencode serve` enforces their permission maps. |
| The model policy + config template | `modelguild/models.policy` and `modelguild/modelguild.conf.example`. |
| The record | `modelguild/logs/` (git-ignored) — every model call, on disk and yours to read (see [The record it keeps](#the-record-it-keeps)). |

- `guild-read` → read-only **ROLE** for opinions and planning (`/guild:consult`, `/guild:panel`, `/guild:workshop`, `/guild:review`): a default-deny allowlist (`"*": deny` at opencode's permission layer) granting exactly a Claude review subagent's tools — `read` + `grep` + `glob` + `webfetch`/`websearch`; mutation and sub-agent spawning (`task`) are denied. **Not a confidentiality boundary: trusted repos only** — it can read any file including your secrets (`.env`, keys, `.aws`/`.ssh`) and reach the web, so a secret can leave to a third-party model. Verified by `modelguild/verify-guild-read.sh`.
- `guild-build` → can edit files for `/guild:delegate`: same allowlist construction, re-allowing only edit/write/patch/bash; everything else is denied. Because `bash` is allowed those non-mutation denies are defense-in-depth, not a guarantee — **review the diff**. Verified by `modelguild/verify-guild-build.sh`.
- `guild-research` → the source-backed `/guild:research` path: **same allow-set as `guild-read`** (`read` + `grep` + `glob` + web); mutation and `task` denied. Same posture — **not a confidentiality boundary, trusted repos only**. Verified by `modelguild/verify-guild-research.sh`.

## Setup

Exactly what you do, start to finish. It's six steps: **(1)** prerequisites, **(2)** install the payload (`init`), **(3)** register the MCP server yourself, **(4)** restart Claude Code so it loads it, **(5)** verify, **(6)** configure which models it uses. Steps 2 and 3 are **separate**: `init` copies the command docs / agent defs / policy template but **does not touch `.mcp.json`** — *you* register the server (step 3), so you choose global vs per-project scope. Step 6 configures *which models* it uses. You want all of them.

### 1. Prerequisites

- **[Node.js](https://nodejs.org)** (ships with `npm`/`npx`) — ModelGuild is a TypeScript CLI + MCP server; you need Node to build and run it.
- **[opencode](https://opencode.ai)** on your PATH, **authenticated to at least one provider**. The MCP server fronts `opencode serve`, so this is what gives Claude access to other models:
  ```bash
  opencode auth login     # interactive OAuth — subscription or free tier, no API keys stored by this tool
  ```
  Repeat it for each provider you want (OpenAI / ChatGPT, GitHub Copilot, Google Gemini, …). `opencode models` lists what your auth actually offers.
- **[Claude Code](https://claude.com/claude-code)** — the driver. ModelGuild is loaded by Claude Code as a project MCP server.
- A **git repo** for the project you install into, so you can review `/guild:delegate` diffs. Not strictly required for the read-only commands.

**Your own MCP servers:** opencode supports MCP, but ModelGuild's hardened agents will **not** use your MCP tools — every agent is a default-deny allowlist (`"*": deny`), and that floor covers MCP tools too (verified: an agent under the floor can't even see them). To let a delegated model reach an MCP tool you must explicitly allow it in the agent def, and that is a security decision, not a convenience one.

### 2. Install the payload (`init`)

This is what makes the `/guild:*` commands exist. `init` copies the command docs / agent defs / policy template into your project, records each written file's SHA-256, and upgrades or removes a file only while its bytes still match that ownership record — files you edited are left alone. **`init` does not write `.mcp.json`** — that's step 3, and it's yours to do. (When it finishes, it prints the exact register command for step 3.)

#### 2a. Recommended — from npm

```bash
cd /path/to/your/project
npx modelguild init
```
Or the one-liner bootstrap (a thin `install.sh` that runs `npx modelguild init` for you, for the classic `curl | bash` habit):
```bash
curl -fsSL https://raw.githubusercontent.com/bencmorrison/modelguild/main/install.sh | bash
```
The bootstrap installs into the current directory; pass `-s -- --dir /path/to/project` to target another. Pin a version with `-s -- --ref 0.5.0` (or `MODELGUILD_REF=0.5.0`).

#### 2b. From source (contributors, or to run an unreleased build)

Clone and build the CLI once:
```bash
git clone https://github.com/bencmorrison/modelguild.git
cd modelguild
npm install && npm run build      # produces dist/cli.js
```
Then place the payload into **your** project:
```bash
node dist/cli.js init --dir /path/to/your/project
```
(Or `cd /path/to/your/project` first and run `node /path/to/modelguild/dist/cli.js init` — `--dir` defaults to the current directory.)

### 3. Register the MCP server yourself

`init` deliberately leaves `.mcp.json` alone so **you** pick the scope. Register the `modelguild` server with Claude Code's CLI — `-s` chooses the scope:

- **`-s user`** — global: available in *all* your projects (written to `~/.claude.json`). The server resolves the active project from its working directory, so one global registration works everywhere.
- **`-s project`** — committed to *this* repo's `.mcp.json` (shared with anyone who clones it).
- **`-s local`** — this project only, private to you (not committed).

#### 3a. Recommended — from npm

```bash
claude mcp add modelguild -s user -- npx -y modelguild serve
```

#### 3b. From source — absolute launch line

If you installed from source (2b), point the registration at your local build instead:
```bash
claude mcp add modelguild -s user -- node /path/to/modelguild/dist/cli.js serve
```
If you move or delete the ModelGuild checkout, re-run this with the new path.

**The MCP server key must be exactly `modelguild`** — the slash commands grant `mcp__modelguild__*` and won't find the tools under any other key.

**Hand-written alternative** (any scope, no CLI): paste a `modelguild` block into the relevant `.mcp.json` yourself — for a project-scoped file that's the block `init` prints when it finishes:
```json
{
  "mcpServers": {
    "modelguild": {
      "command": "npx",
      "args": ["-y", "modelguild", "serve"],
      "env": { "GUILD_PROJECT_DIR": "/path/to/your/project" }
    }
  }
}
```
(From a source build instead, use `"command": "node"` with `"args": ["/path/to/modelguild/dist/cli.js", "serve"]`.)

**Opt-in shortcut:** if you *want* `init` to write the project `.mcp.json` for you (the old behavior), pass `--write-mcp` — e.g. `npx modelguild init --write-mcp --dir /path/to/your/project`. That writes a project-scoped entry (equivalent to `-s project`) and skips the manual register.

### 4. Restart Claude Code

Claude Code reads its MCP registrations **at session start**, so it will not see the server you just registered until you restart it in that project. Quit and reopen Claude Code (or start a fresh session) in `/path/to/your/project`.

### 5. Verify

Run the token-free `doctor` — it checks opencode is present, the MCP registration, the agent defs, and the policy, without calling any model:
```bash
npx modelguild doctor --dir /path/to/your/project
# node /path/to/modelguild/dist/cli.js doctor --dir <project>   # if you installed from source
```
`doctor` detects the registration in **any** scope by asking the Claude CLI (`claude mcp get modelguild`), so a global (`-s user`) registration passes even though it isn't in the project `.mcp.json`. A healthy result looks like:
```
✓ MCP server 'modelguild' registered (found via `claude mcp get`, any scope)
✓ 8/8 command docs present in .claude/commands/guild/
✓ 3/3 hardened agent defs present in .opencode/agent/
✓ model policy present (modelguild/models.policy)
✓ opencode present (…)

doctor: OK
```
If the `claude` CLI isn't on PATH, `doctor` can't see a global registration and instead reports a warning (not a failure) telling you to verify with `claude mcp get modelguild`. Inside the restarted Claude Code, the `/guild:*` commands now appear in the slash-command list and the `guild_*` MCP tools are available. **The first time** Claude Code calls one, it asks a one-time permission for that tool (e.g. `mcp__modelguild__guild_consult`) — approve it (see [Skip the permission prompts](#skip-the-permission-prompts) to pre-approve them all).

### 6. Configure which models it uses

Registering the server (step 3) does not choose *which* models it talks to or what your policy allows — that's this step, and it's separate. Two ways, both effective immediately (no restart):

- **Interactive:** run **`/guild:configure`** inside Claude Code. It interviews you and writes your model policy (deny/ask/allow) and preferred-model defaults to the git-ignored config files.
- **By hand:** edit the two git-ignored files under `modelguild/`:
  - `modelguild/models.policy.local` — per-model `deny`/`ask`/`allow` rules (the committed `modelguild/models.policy` is default-allow).
  - `modelguild/modelguild.conf.local` (copy from `modelguild/modelguild.conf.example`) — your default single model and panel set:
    ```
    GUILD_MODEL=openai/gpt-5
    GUILD_MODELS=openai/gpt-5 google/gemini-2.5-pro
    ```

Prefer a **non-Claude** model for consults so the second opinion is genuinely independent. This step is optional — without it, commands use opencode's default model — but setting a policy and defaults is what makes day-to-day use smooth.

### Updating

Re-run `init` (`npx modelguild init --dir <project>`; from a source build: `node dist/cli.js init --dir <project>`). It's idempotent: it upgrades files you haven't touched (bytes still matching the recorded hash), leaves any file you edited locally alone, and adds new payload files. `init` never touches your MCP registration, so re-running it won't disturb the server you registered in step 3. After a local rebuild (`npm run build`), re-running `init` refreshes the project's payload. There is no separate update mode.

## Usage

Run these inside Claude Code in a project you've installed into:

| Command | What it does |
|---|---|
| `/guild:consult <question>` | Get a second opinion from another LLM on a plan or approach (read-only). Claude weighs it against its own view. |
| `/guild:panel <question>` | Ask 2–3 different models the same question and have Claude synthesize + break ties. Warns if the panel isn't cross-provider. |
| `/guild:workshop <goal>` | A **multi-LLM planning session**: 2–3 models write independent plans, Claude synthesizes, then those same models **critique Claude's synthesis** before Claude dispositions each point into a final plan. ~2 calls per model. |
| `/guild:review <target>` | Findings-first code review by another model, then Claude verifies each finding against the code before reporting. Target a path, the diff, or a branch. |
| `/guild:research <question>` | Source-backed investigation by a **web-capable** model, then Claude fetches the cited sources and verifies each claim before reporting. Fabricated citations get refuted, not repeated. |
| `/guild:delegate <coding task>` | Hand a coding task to another model (it edits files), then Claude reviews the diff. |
| `/guild:collaborate <question>` | Bounded multi-turn peer exchange with another model; Claude dispositions each point (read-only). |
| `/guild:configure` | Interactive setup: writes your model policy and preferred-model defaults to git-ignored config files. |

Examples:
```
/guild:consult Is an actor the right concurrency model here, or should I use a serial queue?
/guild:panel What's the best migration path off Core Data for this app?
/guild:review the uncommitted diff
/guild:delegate Add bounds checking to the ring buffer in src/buffer.c and a test
```

### Picking the model

To see the exact provider/model ids your auth offers, ask Claude to run the `guild_models` tool (or run `opencode models` yourself). Pass a specific model to any command; omit it to use your configured default.

To set **persistent defaults** — a default single model for `/guild:consult` and a default panel set for `/guild:panel` — run **`/guild:configure`** (it walks you through it), or copy `modelguild/modelguild.conf.example` to `modelguild/modelguild.conf.local` (git-ignored) and set:
```
GUILD_MODEL=openai/gpt-5
GUILD_MODELS=openai/gpt-5 google/gemini-2.5-pro
```
These take effect immediately — no restart. (The matching env vars still work as one-off overrides; precedence is arg → env → config file → opencode's default.) Prefer a **non-Claude** model for consults so the second opinion is genuinely independent.

## Troubleshooting

- **`npx modelguild …` says "package not found".** `modelguild` is published to npm, so check spelling and your network (or a stale npm cache — `npm cache verify`). If you're intentionally running an unreleased build, use the from-source path instead: `npm run build` in the checkout, then `node dist/cli.js init --dir <project>` (see [Setup step 2b](#2b-from-source-contributors-or-to-run-an-unreleased-build)).
- **The `/guild:*` commands don't appear in Claude Code.** Restart Claude Code — it only reads its MCP registrations at session start (Setup step 4). Still missing? Confirm the server is registered — `claude mcp get modelguild` (any scope) — and run `doctor` (step 5) to check registration and payload.
- **A `guild_*` tool call errors about opencode.** opencode isn't installed on PATH or isn't authenticated. Run `opencode auth login`, and `opencode models` to confirm at least one provider answers. If you built locally and moved the checkout, the launch `args` path is stale — re-run `claude mcp add` (or edit the registration) with the new path.
- **A model is denied / not allowed.** That's the model policy. Run `/guild:configure`, or edit `modelguild/models.policy.local` (Setup step 6).
- **Not sure what's wrong.** Run `doctor` — it reports each check with `✓`/`✗` and needs no model call.

## Safety

ModelGuild has real, verifiable guardrails — but it is **not a sandbox**. Use it on trusted repositories. See **[SECURITY.md](SECURITY.md)** for the full threat model; the essentials:

- **Read-only commands (`/guild:consult`, `/guild:panel`, `/guild:workshop`, `/guild:review`, `/guild:collaborate`)** run under a default-deny allowlist agent with a review subagent's tools — read, grep/glob, and the web; it cannot mutate, shell out, or spawn subagents. It is **not a confidentiality boundary**: it can read any repo file **including your secrets** and reach the network, so a secret can leave to a third-party model. **Trusted repos only.** Proven by `modelguild/verify-guild-read.sh`.
- **`/guild:research` is the source-backed web path.** Same read + web exposure and same "trusted repos only" posture; its value is the workflow requiring citations and Claude verification. Proven by `modelguild/verify-guild-research.sh`.
- **`/guild:delegate` can edit files and run shell.** Its non-mutation restrictions are defense-in-depth, not a guarantee (a coding task needs `bash`, and `bash` can reach around them), so **the trust boundary is you reviewing the diff.** The tool snapshots the worktree first and records the model's patch separately, so dirty worktrees are allowed.
- **External model output is treated as data, not instructions** — a consulted model can't smuggle commands into Claude's control flow.
- Run `doctor` (step 5 of [Setup](#setup)) to check your setup before relying on any of this.

## The record it keeps

Every model call is logged to `modelguild/logs/<run_id>/calls.jsonl` as three lifecycle entries sharing one `call_id`: `expected-call` before capture setup, `started` before execution, and `completed` after it. Three calls produce nine lifecycle entries. The record includes the exact prompt sent, the model's full untruncated answer, model, agent, and exit status. It's git-ignored and stays on your machine.

This is **receipts**. When Claude tells you "GPT-5 agreed with my approach", that summary is written by the party you'd be checking up on — the log is the other model's *actual words*, on disk and yours to read, so you can check them yourself, diff them against Claude's account, or keep them for later. It's a plain local file, governed by the privacy knobs below. It earned its keep finding real bugs during this project's own development.

- **See it:** `cat modelguild/logs/latest/calls.jsonl | jq`. Verification (built into the server's evidence layer) checks lifecycle cardinality in both directions, capture completeness, referenced artifacts, every entry's self-hash, and the chain; setup failures and mid-flight gaps do not pass as clean.
- **Privacy:** by default the log keeps the full prompt, which means whatever context Claude pasted in from your repo. Set `GUILD_LOG_PROMPTS=hash` (keep a digest, not the text) or `off` in `modelguild/modelguild.conf.local` if that's not OK for your work. Runs older than 14 days are pruned automatically (`GUILD_LOG_RETENTION_DAYS`); `GUILD_LOG=off` turns the whole thing off.
- **What it is not:** tamper-proofing. The hashes catch accidental corruption; they're not a chain of custody, and anything that can write the log can rewrite them.

## Uninstall

```bash
npx modelguild init --uninstall --dir /path/to/your/project
# node /path/to/modelguild/dist/cli.js init --uninstall --dir <project>   # if you installed from source
```
It removes only the files ModelGuild installed and can still prove it owns (by hash); your own files, config, and `modelguild/logs/` are left in place. If a project `.mcp.json` `modelguild` key exists (from `--write-mcp`), uninstall removes it — but a registration you made yourself with `claude mcp add` is yours to remove: `claude mcp remove modelguild` (add `-s user`/`-s local`/`-s project` for a non-default scope). Any Claude Code permission grant you added to `.claude/settings*.json` is yours to remove too.

## Skip the permission prompts

The first time Claude Code calls a ModelGuild MCP tool it asks for permission. Choosing "yes, and don't ask again" persists that tool (e.g. `mcp__modelguild__guild_consult`) into your project's `.claude/settings.local.json` (git-ignored) — per tool, per project, across sessions. Worst case is a handful of one-time prompts. To pre-approve them all up front, add the tool names to `.claude/settings.local.json`:
```json
{
  "permissions": {
    "allow": [
      "mcp__modelguild__guild_consult",
      "mcp__modelguild__guild_panel",
      "mcp__modelguild__guild_research",
      "mcp__modelguild__guild_delegate",
      "mcp__modelguild__guild_models"
    ]
  }
}
```

## Notes & limits

- **Cost**: calls run against your opencode-authenticated providers; usage counts against those plans (free tiers included). `opencode stats` shows token usage/cost.
- **Not just for coding**: `/guild:consult` and `/guild:panel` are great for planning and design reviews, which is often where a second model helps most.
- **Always review `/guild:delegate` diffs** — that human review is the trust boundary for the write path.

## Bugs & feedback

Found a bug, hit a rough edge, or want to suggest something? Please open a **[GitHub issue](https://github.com/bencmorrison/modelguild/issues)**.

What helps most in a bug report:
- The output of `doctor` (`npx modelguild doctor`, or `node <repo>/dist/cli.js doctor` for a source build).
- Which command you ran, and the model it used.
- Your OS. macOS and BSD support is newer and less exercised than Linux, so please say if you're on one.

**Security issues are the exception — do not open a public issue for them.** Report those privately via the [Security tab](https://github.com/bencmorrison/modelguild/security), as described in **[SECURITY.md](SECURITY.md)**. That file also documents what this tool deliberately does *not* guarantee: the read-only agents reach the web by design and can read your secrets, and `/guild:delegate` allows `bash`, so neither is an exfiltration boundary.

## Working on ModelGuild itself

Contributing to ModelGuild (not just using it)? The repo ships a dev container that runs Claude Code and opencode in-container with persistent auth, plus the full TypeScript test suite (`npm test`) and the shell lint/verify scripts. See **[CONTRIBUTING.md](CONTRIBUTING.md)** and **[AGENTS.md](AGENTS.md)**.
