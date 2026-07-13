---
description: Ask two or more different LLMs the same question and synthesize their answers
argument-hint: [question]
allowed-tools: Bash(bash collab/ask.sh:*), Bash(opencode models:*)
---
Get multiple independent perspectives on:

$ARGUMENTS

1. Choose 2-3 models from different providers/families for genuine diversity (run `opencode models` if unsure what's available). Avoid picking the same underlying model twice.
2. Ask each the SAME question, one call per model:
   `bash collab/ask.sh -m <provider/model> "<the question with full context>"`
3. Synthesize: summarize each model's position, call out where they agree and disagree, and give one reasoned recommendation that accounts for the disagreements. Add your own judgment as a distinct, labeled voice — you are the tie-breaker, not just an aggregator.
