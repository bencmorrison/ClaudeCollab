---
description: Interactively set up your ClaudeCollab model policy (deny/ask/allow) and preferred models
argument-hint: (interactive — no arguments needed)
allowed-tools: Bash(opencode models:*), Bash(bash collab/ask.sh --dry-run:*), Bash(COLLAB_CONFIRMED=1 bash collab/ask.sh --dry-run:*), Bash(bash collab/doctor.sh:*), Read, Write, Edit
---
Guide the user through configuring ClaudeCollab's model policy and preferences. This is **interactive** — ASK the user for their choices, don't assume them, and show the result for confirmation before writing anything.

$ARGUMENTS

1. **Show what's available.** Run `opencode models` and present the models grouped by provider, so the user picks from what their auth actually offers. If it errors (not authenticated), tell them to run `opencode auth login` first, then stop.

2. **Explain the model briefly** (one or two lines each):
   - The **policy** has three tiers over glob patterns, **first-match-wins, default-allow**: `deny` (ask.sh hard-refuses it), `ask` (usable only after you confirm — the command sets `COLLAB_CONFIRMED=1`), `allow` (free to use; the default for anything unmatched).
   - **"Preferred" is not a policy tier** — it's your default single model (`COLLAB_MODEL`, used by `/consult`) and your default panel set (`COLLAB_MODELS`, used by `/panel`). Those are environment variables.

3. **Interview** (use AskUserQuestion or plain questions; the user may skip any):
   - Models/providers to **deny** — e.g. one they distrust or that's too expensive. Accept exact ids or globs (`openai/*-terra*`, `*-fast`).
   - Models to gate with **ask** — confirm before each use (e.g. the priciest/slowest).
   - Their **preferred default model** for `/consult` — recommend a **non-Claude** model so opinions are independent.
   - Their **preferred panel set** for `/panel` — 2–3 ordered ids from **different providers** (run `bash collab/panel-models.sh <ids…>` to sanity-check diversity).
   - **Scope:** personal (written to git-ignored `collab/models.policy.local`, **recommended** — never committed) or shared (edit the committed `collab/models.policy` for the whole repo/team).

4. **Draft and confirm.** Show the exact policy file you'll write and get a yes before writing. Ordering matters (first-match-wins): put `deny` lines above `ask` lines above any broad rule, so a specific rule beats a broad one. Keep the shipped comment header if editing the committed file. Comments start with `#`.

5. **Write it.**
   - Personal → write `collab/models.policy.local` (git-ignored; `ask.sh` auto-prefers it over the committed default, and `$COLLAB_POLICY` still overrides both).
   - Shared → edit `collab/models.policy` (and remind them it's committed — everyone gets it).
   - **Preferred models can't be persisted from here** (they're env vars). Print the exact lines for the user to add to their shell profile (e.g. `~/.zshrc`), and mention they take effect after reloading the shell:
     ```
     export COLLAB_MODEL=<their pick>
     export COLLAB_MODELS="<id1> <id2> <id3>"
     ```

6. **Validate.** Run `bash collab/doctor.sh` (confirms the active policy parses and reports the default-model tier), then spot-check the intent with dry-runs (token-free):
   - a **denied** id must refuse: `bash collab/ask.sh --dry-run -m <denied-id> "x"` → exits non-zero, "denied by …";
   - an **allowed** id prints the command and exits 0.
   Report what you verified.

7. **Summarize** what you wrote, where, and when it takes effect (policy file: immediately; exports: after the shell is reloaded). Keep it short.
