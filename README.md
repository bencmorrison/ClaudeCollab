# ClaudeCollab

Let **Claude Code** collaborate with **other LLMs** (OpenAI, GitHub Copilot's model stack, Google Gemini, or anything else) for a second opinion, a multi-model panel, code review, or delegated coding — using **[opencode](https://opencode.ai)** as the gateway.

Claude Code stays the driver. You drop ClaudeCollab into **your own project**, and Claude gains a few slash commands that shell out to opencode. opencode handles model access and auth, so this works off **whatever providers your opencode auth gives you — paid subscriptions or free tiers — with no API keys stored or managed by this tool**.

## How it works

Claude Code cannot itself run a non-Anthropic model (its agent and subagents are always Claude). So instead it *shells out* to opencode, which is model-agnostic:

```
Claude Code  ──(slash command)──▶  collab/ask.sh  ──▶  opencode run  ──▶  GPT / Copilot / Gemini / …
     ▲                                                                              │
     └───────────────────  reads the other model's answer, then reasons over it  ──┘
```

ClaudeCollab is three drop-in directories you add to a project:

| Directory | What it is |
|---|---|
| `.claude/commands/` | The slash commands Claude Code runs (`/consult`, `/panel`, `/review`, `/delegate`, `/collaborate`, `/configure-collab`). |
| `.opencode/agent/` | Three **hardened** opencode agents: `collab-read` (read-only), `collab-build` (the `/delegate` write path), and `collab-research` (the `/research` web path). |
| `collab/` | The `ask.sh` wrapper plus the `log`, `panel`, `doctor`, and `verify` scripts, tests, and the model policy. |
| `collab/logs/` | Git-ignored. A record of every model call, and where `/witness` reports land — see [The record it keeps](#the-record-it-keeps). |

- `collab-read` → read-only **by construction** for opinions (`/consult`, `/panel`, `/review`): a default-deny allowlist (`"*": deny` at opencode's permission layer) that grants **only** reading non-secret files — all mutation, content search/glob, sub-agent spawning, network egress, and secret reads are denied. Verified by `collab/verify-collab-read.sh`.
- `collab-build` → can edit files for `/delegate`: same allowlist construction, re-allowing only edit/write/patch/bash; everything else is denied. Because `bash` is allowed those non-mutation denies are defense-in-depth, not a guarantee — **review the diff**. Verified by `collab/verify-collab-build.sh`.
- `collab-research` → can reach the web for `/research`: same allowlist construction, re-allowing only `webfetch`/`websearch` + reading non-secret files. Mutation, shell, and content search/glob are denied — and because `bash` is denied, the secret-read denies genuinely hold here. But this is the one agent with **both local read and network egress**, so it is *not* an exfiltration boundary: point it at repos whose non-secret contents you'd accept leaking. Verified by `collab/verify-collab-research.sh`.

## Requirements

- **[opencode](https://opencode.ai)** on your PATH, authenticated to at least one provider (below).
- **`jq`** (used by `/collaborate` and the verify scripts).
- A **git repo** for the project you install into (so you can review `/delegate` diffs). Not strictly required for read-only commands.

## Install

ClaudeCollab installs *into* whatever project you want Claude Code to have these commands in. It only adds its own files — if you already have a file at one of its paths (a same-named slash command, agent, or something under `collab/`), the installer **skips it with a warning** rather than overwriting, and uninstall never deletes it.

**One-liner** (clones ClaudeCollab and installs into the current directory):
```bash
curl -fsSL https://raw.githubusercontent.com/bencmorrison/ClaudeCollab/main/install.sh | bash
```

**Or from a clone** (lets you inspect first — recommended):
```bash
git clone https://github.com/bencmorrison/ClaudeCollab.git /tmp/claudecollab
cd /path/to/your/project
bash /tmp/claudecollab/install.sh          # installs into the current dir
# or target another dir explicitly:
bash /tmp/claudecollab/install.sh --dest /path/to/your/project
```

The installer copies the three directories in, sets the scripts executable, and adds the per-user config files to your project's `.gitignore`. Run `bash /tmp/claudecollab/install.sh --help` for options.

Then authenticate opencode and verify:
```bash
opencode auth login     # interactive OAuth — your provider login (subscription or free tier), no API keys
opencode models         # confirm you can see models
bash collab/doctor.sh   # preflight check of the whole setup (token-free)
```
Repeat `opencode auth login` for each provider you want (OpenAI / ChatGPT, GitHub Copilot, Google Gemini, …).

## Usage

Run these inside Claude Code in a project you've installed into:

| Command | What it does |
|---|---|
| `/consult <question>` | Get a second opinion from another LLM on a plan or approach (read-only). Claude weighs it against its own view. |
| `/panel <question>` | Ask 2–3 different models the same question and have Claude synthesize + break ties. Warns if the panel isn't cross-provider. |
| `/workshop <goal>` | A **multi-LLM planning session**: 2–3 models write independent plans, Claude synthesizes them, then those same models **critique Claude's synthesis** ("what did you drop?") before Claude dispositions each point into a final plan. ~2 calls per model. |
| `/review <target>` | Findings-first code review by another model, then Claude verifies each finding against the code before reporting. Target a path, the diff, or a branch. |
| `/research <question>` | Source-backed investigation by a **web-capable** model, then Claude fetches the cited sources and verifies each claim before reporting. Fabricated citations get refuted, not repeated. |
| `/delegate <coding task>` | Hand a coding task to another model (it edits files), then Claude reviews the diff. |
| `/collaborate <question>` | Bounded multi-turn peer exchange with another model; Claude dispositions each point (read-only). |
| `/configure-collab` | Interactive setup: writes your model policy and preferred-model defaults to git-ignored config files. |

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
- **`/research` trades egress for capability, on purpose.** It's the only path with both local read and network access, so while it can't mutate, shell out, or grep (and therefore *can't* reach your `.env`/keys), a non-secret file it reads could in principle leave over an outbound fetch — and fetched pages are attacker-controlled. Use it on repos whose non-secret contents you'd accept leaking. Proven by `collab/verify-collab-research.sh`.
- **`/delegate` can edit files and run shell.** Its non-mutation restrictions are defense-in-depth, not a guarantee (a coding task needs `bash`, and `bash` can reach around them), so **the trust boundary is you reviewing the diff.** The wrapper refuses to delegate on a dirty worktree and prints the pre-edit `HEAD` so the diff is exactly the model's work.
- **External model output is treated as data, not instructions** — a consulted model can't smuggle commands into Claude's control flow.
- Run `bash collab/doctor.sh` to check your setup before relying on any of this.

## The record it keeps

Every model call is logged to `collab/logs/<run_id>/calls.jsonl` — the exact prompt sent, the model's full untruncated answer, which model and agent, and the exit code. It's git-ignored and stays on your machine.

This isn't for debugging. When Claude tells you "GPT-5 agreed with my approach", that summary is written by the party you'd be checking up on. The log is the other model's actual words, so you can read them yourself — and it's the data source for the planned `/witness` command, which hands a *different* model the log and asks whether Claude's account of the exchange holds up.

- **See it:** `cat collab/logs/latest/calls.jsonl | jq` — or check a run is complete with `bash collab/log.sh verify $(readlink collab/logs/latest)`. A call that died mid-flight shows up as a gap rather than passing for a clean record.
- **Privacy:** by default the log keeps the full prompt, which means whatever context Claude pasted in from your repo. Set `COLLAB_LOG_PROMPTS=hash` (keep a digest, not the text) or `off` in `collab/collab.conf.local` if that's not OK for your work. Runs older than 14 days are pruned automatically (`COLLAB_LOG_RETENTION_DAYS`); `COLLAB_LOG=off` turns the whole thing off.
- **What it is not:** tamper-proofing. The hashes catch accidental corruption; they're not a chain of custody, and anything that can write the log can rewrite them.

### `/witness` — have another model check Claude's account

`/witness` hands the log to a **non-Claude** model whose only capability is reading `collab/logs/` — no shell, no web, and no access to your source, so it audits the record rather than drifting into reviewing your code. It reports what Claude dropped, misrepresented, or flattened, with the model's actual words next to Claude's rendering of them, and a verdict of OK / Concerns / Inconclusive. The report is saved under `collab/logs/<run_id>/reports/`, so Claude isn't the only thing standing between you and it.

It refuses to audit a log that fails its integrity check, rather than reporting "clean" over a gap. Set `COLLAB_WATCH_MODEL` in `collab/collab.conf.local` to pin the auditor; a Claude model is refused unless you explicitly confirm it.

**The honest bound, stated plainly:** Claude writes the prompt the auditor works from, and picks which run to audit. What's caught *by construction* is omission and misrepresentation — the watcher reads the whole raw log, so Claude cannot hide what another model said. What is **not** caught is Claude's dispositional honesty: a subtly biased prompt is still Claude's to write. Closing that would need Claude Code to expose its own decision state unmediated, and it doesn't. A clean verdict means one bounded check found nothing — not that the engagement was honest.

## Uninstall

From a clone, point the installer at the project you installed into:
```bash
bash /tmp/claudecollab/install.sh --uninstall --dest /path/to/your/project
```
It reads the manifest it wrote at install time and removes exactly the files it installed — its `collab/` scripts, slash commands, opencode agents, and its `.gitignore` block — then removes those directories only if they're now empty. Anything you added yourself (your own commands, agents, files under `collab/`, or `.gitignore` lines) is left untouched — **including `collab/logs/`**, which is your record of what the models actually said, not ours to delete. Any Claude Code permission grants you added to `.claude/settings*.json` (below) are yours to remove.

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

## Working on ClaudeCollab itself

Contributing to ClaudeCollab (not just using it)? The repo ships a dev container that runs Claude Code and opencode in-container with persistent auth, plus the full test/verify suite. See **[CONTRIBUTING.md](CONTRIBUTING.md)** and **[AGENTS.md](AGENTS.md)**.
