---
description: Interactively set up your ClaudeCollab model policy (deny/ask/allow) and preferred models
argument-hint: (interactive — no arguments needed)
allowed-tools: mcp__claudecollab__collab_models, Bash(npx claudecollab doctor:*), Bash(claudecollab doctor:*), Read, Write, Edit
---
Guide the user through configuring ClaudeCollab's model policy and preferences. This is **interactive** — ASK the user for their choices, don't assume them, and show the result for confirmation before writing anything.

$ARGUMENTS

1. **Show what's available.** Call the `collab_models` MCP tool and present the models grouped by provider, so the user picks from what their auth actually offers (`structuredContent.providers` groups them; each provider's `default` is shown too). If it returns `isError` (e.g. not authenticated), tell them to run `opencode auth login` first, then stop.

2. **Explain the model briefly** (one or two lines each):
   - The **policy** has three tiers over glob patterns, **first-match-wins, default-allow**: `deny` (the collab tools hard-refuse it — the call returns `isError`), `ask` (usable only after you confirm — the tool call carries `confirmed: true`, which represents the user's approval, never yours), `allow` (free to use; the default for anything unmatched). It is enforced by every collab tool (`collab_consult`, `collab_panel`, `collab_research`, `collab_delegate`) on each call.
   - **"Preferred" is not a policy tier** — it's your default single model (used by `/collab:consult`) and your default panel set (used by `/collab:panel`). These live in a git-ignored config file `collab/collab.conf.local` (as `COLLAB_MODEL=` / `COLLAB_MODELS=`), which you'll write here so they persist. (The matching env vars still work as one-off overrides.)

3. **Interview** (use AskUserQuestion or plain questions; the user may skip any):
   - Models/providers to **deny** — e.g. one they distrust or that's too expensive. Accept exact ids or globs (`openai/*-terra*`, `*-fast`).
   - Models to gate with **ask** — confirm before each use (e.g. the priciest/slowest).
   - Their **preferred default model** for `/collab:consult` — recommend a **non-Claude** model so opinions are independent.
   - Their **preferred panel set** for `/collab:panel` — 2–3 ordered ids from **different providers** (`collab_panel` will warn if the set isn't diverse; you can also eyeball the `collab_models` provider grouping to pick across families).
   - **Scope:** personal (written to git-ignored `collab/models.policy.local`, **recommended** — never committed) or shared (edit the committed `collab/models.policy` for the whole repo/team).

4. **Draft and confirm.** Show the exact policy file you'll write and get a yes before writing. Ordering matters (first-match-wins): put `deny` lines above `ask` lines above any broad rule, so a specific rule beats a broad one. Keep the shipped comment header if editing the committed file. Comments start with `#`.

5. **Write it.** These are the exact files the TS config resolver reads (`src/config.ts` reads `collab.conf.local`; `src/policy.ts` reads the policy files) — the locations and formats are unchanged from the bash era.
   - Personal → write `collab/models.policy.local` (git-ignored). Effective resolution is `$COLLAB_POLICY` when set, otherwise this local file when it has at least one rule, otherwise committed `collab/models.policy`.
   - Shared → edit `collab/models.policy` (and remind them it's committed — everyone gets it).
   - **Preferred models** → write them to `collab/collab.conf.local` (git-ignored; the collab tools read it). Use `collab/collab.conf.example` as the template. Two lines (omit either if the user didn't pick one):
     ```
     COLLAB_MODEL=<their pick>
     COLLAB_MODELS=<id1> <id2> <id3>
     ```
     These take effect immediately (no restart needed) — that's the point of using a file. Do NOT print `export` lines; the file is the durable home now.
   - **Note on the collab root:** the tools resolve the `collab/` directory as `$COLLAB_ROOT`, else `<cwd>/collab/`, else `~/.claude/collab/`. Write into whichever root is active for this project (normally the project's own `collab/`).

6. **Validate.** Run `npx claudecollab doctor` (or `claudecollab doctor` if it's on PATH) — a token-free check that the MCP server is registered, the command docs and hardened agent defs are present, and the model policy file exists. Then confirm intent yourself:
   - The policy is **first-match-wins, default-allow**, and takes effect immediately — re-read the file you wrote and walk the user through which of their models land in `deny` / `ask` / `allow` under it.
   - If you set a panel, sanity-check that its members come from **different providers** (single-provider sets are "diversity theater"); `collab_panel` will also surface a warning at call time.
   Report what you verified.

7. **Summarize** what you wrote and where (`collab/models.policy.local` for the policy, `collab/collab.conf.local` for preferred models — both git-ignored, both effective immediately). Keep it short.
