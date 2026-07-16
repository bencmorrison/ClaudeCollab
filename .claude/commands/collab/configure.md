---
description: Interactively set up your ClaudeCollab model policy (deny/ask/allow) and preferred models
argument-hint: (interactive — no arguments needed)
allowed-tools: Bash(opencode models:*), Bash(bash collab/ask.sh --dry-run:*), Bash(COLLAB_CONFIRMED=1 bash collab/ask.sh --dry-run:*), Bash(bash collab/panel-models.sh:*), Bash(bash collab/doctor.sh:*), Read, Write, Edit
---
Guide the user through configuring ClaudeCollab's model policy and preferences. This is **interactive** — ASK the user for their choices, don't assume them, and show the result for confirmation before writing anything.

$ARGUMENTS

1. **Show what's available.** Run `opencode models` and present the models grouped by provider, so the user picks from what their auth actually offers. If it errors (not authenticated), tell them to run `opencode auth login` first, then stop.

2. **Explain the model briefly** (one or two lines each):
   - The **policy** has three tiers over glob patterns, **first-match-wins, default-allow**: `deny` (ask.sh hard-refuses it), `ask` (usable only after you confirm — the command sets `COLLAB_CONFIRMED=1`), `allow` (free to use; the default for anything unmatched).
   - **"Preferred" is not a policy tier** — it's your default single model (used by `/collab:consult`) and your default panel set (used by `/collab:panel`). These live in a git-ignored config file `collab/collab.conf.local` (as `COLLAB_MODEL=` / `COLLAB_MODELS=`), which you'll write here so they persist. (The matching env vars still work as one-off overrides.)

3. **Interview** (use AskUserQuestion or plain questions; the user may skip any):
   - Models/providers to **deny** — e.g. one they distrust or that's too expensive. Accept exact ids or globs (`openai/*-terra*`, `*-fast`).
   - Models to gate with **ask** — confirm before each use (e.g. the priciest/slowest).
   - Their **preferred default model** for `/collab:consult` — recommend a **non-Claude** model so opinions are independent.
   - Their **preferred panel set** for `/collab:panel` — 2–3 ordered ids from **different providers** (run `bash collab/panel-models.sh <ids…>` to sanity-check diversity).
   - **Scope:** personal (written to git-ignored `collab/models.policy.local`, **recommended** — never committed) or shared (edit the committed `collab/models.policy` for the whole repo/team).

4. **Draft and confirm.** Show the exact policy file you'll write and get a yes before writing. Ordering matters (first-match-wins): put `deny` lines above `ask` lines above any broad rule, so a specific rule beats a broad one. Keep the shipped comment header if editing the committed file. Comments start with `#`.

5. **Write it.**
   - Personal → write `collab/models.policy.local` (git-ignored). Effective resolution is `$COLLAB_POLICY` when set, otherwise this local file when it has at least one rule, otherwise committed `collab/models.policy`.
   - Shared → edit `collab/models.policy` (and remind them it's committed — everyone gets it).
   - **Preferred models** → write them to `collab/collab.conf.local` (git-ignored; `ask.sh`/`panel-models.sh` read it). Use `collab/collab.conf.example` as the template. Two lines (omit either if the user didn't pick one):
     ```
     COLLAB_MODEL=<their pick>
     COLLAB_MODELS=<id1> <id2> <id3>
     ```
     These take effect immediately (no shell reload needed) — that's the point of using a file. Do NOT print `export` lines; the file is the durable home now.

6. **Validate.** Run `bash collab/doctor.sh` — it confirms the active policy parses, checks the default model's tier, **and now policy-checks each `/collab:panel` member** (so a denied panel member is caught here, not at runtime). Then spot-check intent with dry-runs (token-free):
   - a **denied** id must refuse: `bash collab/ask.sh --dry-run -m <denied-id> "x"` → exits 3, "denied by …";
   - an **allowed** id prints the command and exits 0;
   - if you set a panel, also confirm each member: `bash collab/ask.sh --dry-run -m <panel-id> "x"` per id (`panel-models.sh` checks *diversity*, not policy).
   Report what you verified.

7. **Summarize** what you wrote and where (`collab/models.policy.local` for the policy, `collab/collab.conf.local` for preferred models — both git-ignored, both effective immediately). Keep it short.
