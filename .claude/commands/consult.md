---
description: Get a second opinion from another LLM (via opencode) on a question, plan, or approach
argument-hint: [question or topic]
allowed-tools: Bash(bash collab/ask.sh:*), Bash(COLLAB_CONFIRMED=1 bash collab/ask.sh:*), Bash(opencode models:*), Read
---
Get an outside perspective from a different LLM on:

$ARGUMENTS

1. Run `bash collab/ask.sh "<restate the question with enough context from our conversation that a fresh model can answer standalone>"`. This uses opencode's read-only `plan` agent, so it will not modify any files.
   - To target a specific model, add `-m provider/model` (run `opencode models` to see what's available). Prefer a non-Claude model so the perspective is genuinely independent.
   - **Model policy:** check `collab/models.policy` before choosing. Never use a model matched by a `deny` rule; if your choice matches an `ask` rule, confirm with the user first, then invoke as `COLLAB_CONFIRMED=1 bash collab/ask.sh …`. Always state the exact `provider/model` id you used.
2. Read its answer, then weigh it against your own view. State explicitly where you agree, where you disagree and why, and your final recommendation. Do not simply defer to it — treat it as one input.
