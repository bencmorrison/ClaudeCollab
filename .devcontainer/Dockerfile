# ClaudeCollab dev container.
# Node base (Claude Code and opencode are both distributed via npm) with the two
# agents and a few CLI conveniences preinstalled.
FROM mcr.microsoft.com/devcontainers/javascript-node:22

# The collaborating agents, installed globally so they're on PATH for the `node` user.
RUN npm install -g opencode-ai @anthropic-ai/claude-code \
    && npm cache clean --force

# CLI tools the slash commands and general dev work lean on.
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends jq ripgrep less \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
