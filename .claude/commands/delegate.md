---
description: Delegate a coding task to another LLM agent (opencode) that can edit files, then review its work
argument-hint: [coding task]
allowed-tools: Bash(bash collab/ask.sh:*), Bash(COLLAB_CONFIRMED=1 bash collab/ask.sh:*), Bash(git diff:*), Bash(git status:*), Read, Edit
---
Delegate this coding task to another LLM via opencode, then review the result. opencode runs in this repo and CAN edit files.

Task:
$ARGUMENTS

1. Run `bash collab/ask.sh --edit "<the task with full context: target files, constraints, and how to verify>"`. `--edit` uses opencode's `build` agent with auto-approve, so it will apply changes directly.
   - Add `-m provider/model` to choose which model does the work.
   - **Model policy:** check `collab/models.policy` before choosing. Never delegate to a `deny`-matched model; if your choice matches an `ask` rule, confirm with the user first, then invoke as `COLLAB_CONFIRMED=1 bash collab/ask.sh --edit …`. State the exact model id used.
   - An **Anthropic model is a valid choice** here when you're coordinating — you're delegating and reviewing, not authoring, so an Anthropic agent doing the work is legitimate diversity, not redundancy.
2. Inspect what actually changed with `git status` and `git diff` (or read the affected files). Do not assume it is correct or complete.
3. Report clearly: what the other model changed, whether it's correct, and anything you had to fix or refine. Keep your changes distinct from the delegated model's in your summary.
