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
| `.claude/commands/collab/` | The slash commands Claude Code runs. The `collab/` folder is the namespace: they appear as `/collab:consult`, `/collab:panel`, `/collab:workshop`, `/collab:review`, `/collab:research`, `/collab:delegate`, `/collab:collaborate`, `/collab:witness`, `/collab:configure` — so they can't clash with commands you already have. |
| `.opencode/agent/` | Four **hardened** opencode agents: `collab-read` (read-only + web), `collab-build` (the `/collab:delegate` write path), `collab-research` (the `/collab:research` source-backed workflow), and `collab-watch` (the `/collab:witness` evidence-log auditor). |
| `collab/` | The `ask.sh` wrapper plus the `log`, `panel`, `doctor`, and `verify` scripts, tests, and the model policy. |
| `collab/logs/` | Git-ignored. A record of every model call, and where `/collab:witness` reports land — see [The record it keeps](#the-record-it-keeps). |

- `collab-read` → read-only **by construction** for opinions and planning (`/collab:consult`, `/collab:panel`, `/collab:workshop`, `/collab:review`): a default-deny allowlist (`"*": deny` at opencode's permission layer) that grants file reads plus `webfetch`/`websearch` — mutation, content search/glob, and sub-agent spawning are denied, and an **enumerated list** of credential paths (`.env`, keys, `.ssh/**`, `.aws/**`, `credentials*`) is denied under `read`. It is **not an exfiltration boundary** for repo contents, and the credential denies are a **list, not a boundary** — a secret in a file matching none of them (`.npmrc`, `.git/config`, `terraform.tfvars`) is readable. Verified by `collab/verify-collab-read.sh`.
- `collab-build` → can edit files for `/collab:delegate`: same allowlist construction, re-allowing only edit/write/patch/bash; everything else is denied. Because `bash` is allowed those non-mutation denies are defense-in-depth, not a guarantee — **review the diff**. Verified by `collab/verify-collab-build.sh`.
- `collab-research` → the source-backed `/collab:research` workflow agent: same allowlist construction, re-allowing only `webfetch`/`websearch` + reading non-secret files. Mutation, shell, and content search/glob are denied — and because `bash` is denied, the secret-read denies genuinely hold here. Like `collab-read`, local read + web means it is *not* an exfiltration boundary for non-secret contents. Verified by `collab/verify-collab-research.sh`.

## Requirements

- **[opencode](https://opencode.ai)** on your PATH, authenticated to at least one provider (below).
- **`jq`** (used by `/collab:collaborate` and the verify scripts).
- A **git repo** for the project you install into (so you can review `/collab:delegate` diffs). Not strictly required for read-only commands.

**MCP servers:** opencode supports MCP, but ClaudeCollab's agents will **not** use your MCP tools, and installing the same servers you gave Claude Code changes nothing on its own. Every agent here is a default-deny allowlist (`"*": deny`), and that floor covers MCP tools too — verified: an agent under the floor cannot even see them, while opencode's unrestricted built-in agent calls them fine. If you want a delegated model to reach an MCP, you must **explicitly allow that tool** in the agent def, and that is a security decision rather than a convenience one: a file-reading MCP is **not** covered by the secret-file globs (those protect the `read` tool, not someone else's). Default-deny means a new MCP can't quietly widen what a delegated model can do.

## Install

ClaudeCollab installs *into* whatever project you want Claude Code to have these commands in. It copies an explicit file inventory, records each installed file's SHA-256, and upgrades or removes it only while its bytes still match that ownership record. Existing, locally changed, ambiguous legacy, and unverified files are conservatively retained.

**One-liner** (installs the **latest release** into the current directory):
```bash
curl -fsSL https://raw.githubusercontent.com/bencmorrison/ClaudeCollab/main/install.sh | bash
```

This fetches the latest release **tag**, not the tip of `main` — `main` is development, and you should not be running it by accident. The installer resolves and prints the release it picked before installing anything.

**Or from a clone** (lets you inspect first — recommended):
```bash
git clone --branch v0.1.0 https://github.com/bencmorrison/ClaudeCollab.git /tmp/claudecollab
cd /path/to/your/project
bash /tmp/claudecollab/install.sh          # installs into the current dir
# or target another dir explicitly:
bash /tmp/claudecollab/install.sh --dest /path/to/your/project
```

Run from a clone, the installer uses **that clone's** files as-is — so the ref you checked out is the ref you get, and what you inspected is what lands.

**Pinning a version**, which you want in anything reproducible — `--ref` takes any tag or branch, and always fetches it from the remote:
```bash
# a specific release
curl -fsSL https://raw.githubusercontent.com/bencmorrison/ClaudeCollab/main/install.sh | bash -s -- --ref v0.1.0

# development tip, if you want unreleased changes
curl -fsSL https://raw.githubusercontent.com/bencmorrison/ClaudeCollab/main/install.sh | bash -s -- --ref main
```
`CLAUDECOLLAB_REF=v0.1.0` does the same thing as `--ref v0.1.0`.

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
| `/collab:consult <question>` | Get a second opinion from another LLM on a plan or approach (read-only). Claude weighs it against its own view. |
| `/collab:panel <question>` | Ask 2–3 different models the same question and have Claude synthesize + break ties. Warns if the panel isn't cross-provider. |
| `/collab:workshop <goal>` | A **multi-LLM planning session**: 2–3 models write independent plans, Claude synthesizes them, then those same models **critique Claude's synthesis** ("what did you drop?") before Claude dispositions each point into a final plan. ~2 calls per model. |
| `/collab:review <target>` | Findings-first code review by another model, then Claude verifies each finding against the code before reporting. Target a path, the diff, or a branch. |
| `/collab:research <question>` | Source-backed investigation by a **web-capable** model, then Claude fetches the cited sources and verifies each claim before reporting. Fabricated citations get refuted, not repeated. |
| `/collab:delegate <coding task>` | Hand a coding task to another model (it edits files), then Claude reviews the diff. |
| `/collab:collaborate <question>` | Bounded multi-turn peer exchange with another model; Claude dispositions each point (read-only). |
| `/collab:witness <run>` | Have a non-Claude model audit the evidence log against Claude's account of what the models said. |
| `/collab:configure` | Interactive setup: writes your model policy and preferred-model defaults to git-ignored config files. |

Examples:
```
/collab:consult Is an actor the right concurrency model here, or should I use a serial queue?
/collab:panel What's the best migration path off Core Data for this app?
/collab:review the uncommitted diff
/collab:delegate Add bounds checking to the ring buffer in src/buffer.c and a test
```

### Picking the model

By default `collab/ask.sh` uses opencode's configured default model. To choose per call:
```bash
collab/ask.sh -m openai/gpt-5 "..."
collab/ask.sh -m google/gemini-2.5-pro "..."
```
Run `opencode models` to see the exact provider/model ids available with your auth.

To set **persistent defaults** — a default single model for `/collab:consult` and a default panel set for `/collab:panel` — run **`/collab:configure`** (it walks you through it), or copy `collab/collab.conf.example` to `collab/collab.conf.local` (git-ignored) and set:
```
COLLAB_MODEL=openai/gpt-5
COLLAB_MODELS=openai/gpt-5 google/gemini-2.5-pro
```
These take effect immediately — no shell reload. (Env vars `COLLAB_MODEL`/`COLLAB_MODELS` still work as one-off overrides; precedence is `-m` flag / args → env → config file → opencode's default.) Prefer a **non-Claude** model for consults so the second opinion is genuinely independent.

## Direct use of the wrapper

The slash commands are thin wrappers over one script you can also call yourself:
```bash
collab/ask.sh [-m provider/model] [-a collab-read|collab-build|collab-research|collab-watch|plan|build] [--edit|--research|--watch] <prompt...>
```
See the header of [`collab/ask.sh`](collab/ask.sh) (or `bash collab/ask.sh -h`) for the full interface.

## Safety

ClaudeCollab has real, verifiable guardrails — but it is **not a sandbox**. Use it on trusted repositories. See **[SECURITY.md](SECURITY.md)** for the full threat model; the essentials:

- **Read-only commands (`/collab:consult`, `/collab:panel`, `/collab:workshop`, `/collab:review`, `/collab:collaborate`)** run under a default-deny allowlist agent that can read non-secret files and use the web. It cannot mutate, shell out, spawn subagents, grep/glob, or read secret-glob files. This is not an exfiltration boundary for non-secret repo contents. Proven by `collab/verify-collab-read.sh`.
- **`/collab:research` is the source-backed web workflow.** It has the same local read + web exposure; its value is the command workflow requiring citations and Claude verification. Proven by `collab/verify-collab-research.sh`.
- **`/collab:delegate` can edit files and run shell.** Its non-mutation restrictions are defense-in-depth, not a guarantee (a coding task needs `bash`, and `bash` can reach around them), so **the trust boundary is you reviewing the diff.** The wrapper snapshots the worktree first and records the model's patch separately, so dirty worktrees are allowed.
- **External model output is treated as data, not instructions** — a consulted model can't smuggle commands into Claude's control flow.
- Run `bash collab/doctor.sh` to check your setup before relying on any of this.

## The record it keeps

Every model call is logged to `collab/logs/<run_id>/calls.jsonl` as three lifecycle entries sharing one `call_id`: `expected-call` before capture setup, `started` before execution, and `completed` after it. Three calls produce nine lifecycle entries. The record includes the exact prompt sent, the model's full untruncated answer, model, agent, and exit code. It's git-ignored and stays on your machine.

This isn't for debugging. When Claude tells you "GPT-5 agreed with my approach", that summary is written by the party you'd be checking up on. The log is the other model's actual words, so you can read them yourself — and it's the data source for the `/collab:witness` command, which hands a *different* model the log and asks whether Claude's account of the exchange holds up.

- **See it:** `cat collab/logs/latest/calls.jsonl | jq` — or check a run with `bash collab/log.sh verify $(readlink collab/logs/latest)`. Verification checks lifecycle cardinality, capture completeness, referenced artifacts, every entry's self-hash, and the chain; setup failures and mid-flight gaps do not pass as clean.
- **Privacy:** by default the log keeps the full prompt, which means whatever context Claude pasted in from your repo. Set `COLLAB_LOG_PROMPTS=hash` (keep a digest, not the text) or `off` in `collab/collab.conf.local` if that's not OK for your work. Runs older than 14 days are pruned automatically (`COLLAB_LOG_RETENTION_DAYS`); `COLLAB_LOG=off` turns the whole thing off.
- **What it is not:** tamper-proofing. The hashes catch accidental corruption; they're not a chain of custody, and anything that can write the log can rewrite them.
- **Custom location:** keep logs at the default `collab/logs` location if you use `/collab:witness`. The logger accepts `COLLAB_LOG_DIR`, but the watcher is intentionally limited to `collab/logs/**`; a path outside that scope cannot be audited and the command stops rather than running without evidence.

### `/collab:witness` — have another model check Claude's account

`/collab:witness` hands the log to a **non-Claude** model whose only capability is reading `collab/logs/` — no shell, no web, and no access to your source, so it audits the record rather than drifting into reviewing your code. It reports what Claude dropped, misrepresented, or flattened, with the model's actual words next to Claude's rendering of them, and a verdict of OK / Concerns / Inconclusive. The report is saved under `collab/logs/<run_id>/reports/`, so Claude isn't the only thing standing between you and it.

Report filenames are deterministic: the exact provider/model id is sanitized by replacing each maximal run outside ASCII `[A-Za-z0-9._-]` with `-`, trimming leading/trailing `-`, and using `model` if the result is empty.

It refuses to audit a log that fails its integrity check, rather than reporting "clean" over a gap. Set `COLLAB_WATCH_MODEL` in `collab/collab.conf.local` to pin the auditor; a Claude model is refused unless you explicitly confirm it.

**The honest bound, stated plainly:** Claude writes the prompt the auditor works from, and picks which run to audit. What's caught *by construction* is omission and misrepresentation — the watcher reads the whole raw log, so Claude cannot hide what another model said. What is **not** caught is Claude's dispositional honesty: a subtly biased prompt is still Claude's to write. Closing that would need Claude Code to expose its own decision state unmediated, and it doesn't. A clean verdict means one bounded check found nothing — not that the engagement was honest.

## Uninstall

From a clone, point the installer at the project you installed into:
```bash
bash /tmp/claudecollab/install.sh --uninstall --dest /path/to/your/project
```
It uses the path manifest as an index and the recorded SHA-256 values as ownership proof. Only byte-matching files are removed; changed or unverified files remain, and without hashes or a source payload it refuses to guess from hardcoded paths. Directories are removed only when empty. Anything you added yourself is left untouched, including `collab/logs/`. Any Claude Code permission grants you added to `.claude/settings*.json` are yours to remove.

## Optional: skip the permission prompts

The first time Claude Code runs `collab/ask.sh` it will ask for permission. To pre-approve, add this to `.claude/settings.json` (or your local `.claude/settings.local.json`, which is git-ignored):
```json
{
  "permissions": {
    "allow": [
      "Bash(bash collab/ask.sh:*)",
      "Bash(COLLAB_CONFIRMED=1 bash collab/ask.sh:*)",
      "Bash(COLLAB_COMMAND=/collab:* bash collab/ask.sh:*)",
      "Bash(COLLAB_COMMAND=/collab:* COLLAB_CONFIRMED=1 bash collab/ask.sh:*)",
      "Bash(COLLAB_RUN_ID=* COLLAB_COMMAND=/collab:* bash collab/ask.sh:*)",
      "Bash(COLLAB_RUN_ID=* COLLAB_COMMAND=/collab:* COLLAB_CONFIRMED=1 bash collab/ask.sh:*)",
      "Bash(RUN=$(bash collab/log.sh new-run:*))",
      "Bash(bash collab/log.sh path:*)",
      "Bash(bash collab/log.sh latest:*)",
      "Bash(bash collab/log.sh verify:*)",
      "Bash(printf *| bash collab/log.sh final:*)",
      "Bash(bash collab/panel-models.sh:*)",
      "Bash(bash collab/doctor.sh:*)",
      "Bash(opencode models:*)",
      "Bash(git status:*)",
      "Bash(git diff:*)",
      "Bash(git log:*)",
      "Bash(git ls-files:*)"
    ]
  }
}
```

The `log.sh` entries name **five subcommands rather than `log.sh:*`** — deliberately. A wildcard also pre-approves `log.sh prune`, which deletes old run directories, and nothing here needs it (`ask.sh` writes the log itself; the commands only read it and append `final`). Pruning still works when you approve it or run it yourself.

## Notes & limits

- **Cost**: calls run against your opencode-authenticated providers; usage counts against those plans (free tiers included). `opencode stats` shows token usage/cost.
- **`--auto`**: the hardened agents have explicit allow/deny rules, so `--auto` is not what grants their tools. It only matters on weaker fallback agents with `ask` rules. Always review `/collab:delegate` diffs.
- **Not just for coding**: `/collab:consult` and `/collab:panel` are great for planning and design reviews, which is often where a second model helps most.

## Bugs & feedback

Found a bug, hit a rough edge, or want to suggest something? Please open a **[GitHub issue](https://github.com/bencmorrison/ClaudeCollab/issues)**.

What helps most in a bug report:
- The output of `bash collab/doctor.sh`, which covers your tool versions, auth state, policy tier, and the agent-permission proofs in one go.
- Which command you ran, and the exact `collab:` line `ask.sh` echoed to stderr (it names the model and agent it used).
- Your OS. macOS and BSD support is newer and less exercised than Linux, so please say if you're on one.

**Security issues are the exception — do not open a public issue for them.** Report those privately via the [Security tab](https://github.com/bencmorrison/ClaudeCollab/security), as described in **[SECURITY.md](SECURITY.md)**. That file also documents what this tool deliberately does *not* guarantee, which is worth reading before reporting: the read-only agents reach the web by design, and `/collab:delegate` allows `bash`, so neither is an exfiltration boundary.

## Working on ClaudeCollab itself

Contributing to ClaudeCollab (not just using it)? The repo ships a dev container that runs Claude Code and opencode in-container with persistent auth, plus the full test/verify suite. See **[CONTRIBUTING.md](CONTRIBUTING.md)** and **[AGENTS.md](AGENTS.md)**.
