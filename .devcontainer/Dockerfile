# ClaudeCollab dev container.
# Node base (Claude Code and opencode are both distributed via npm) with the two
# agents and a few CLI conveniences preinstalled.
FROM mcr.microsoft.com/devcontainers/javascript-node:22

# The collaborating agents, installed globally so they're on PATH for the `node` user.
RUN npm install -g opencode-ai @anthropic-ai/claude-code \
    && npm cache clean --force

# CLI tools the slash commands and general dev work lean on.
#   jq       — /collaborate (--emit-session) and the verify scripts
#   ripgrep  — fast search
#   less     — pager
#   shellcheck — the lint CI enforces over all *.sh; installed here so the same
#               check runs locally before a push (CI installs its own copy).
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends jq ripgrep less shellcheck \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pre-create the home dirs the agents write their state into, owned by `node`.
# The credential FILES are bind-mounted into these dirs at runtime; if the dirs
# don't already exist, Docker creates them as root, which blocks opencode and
# Claude Code (running as `node`) from writing their db/state/projects.
RUN mkdir -p /home/node/.local/share/opencode \
             /home/node/.local/state \
             /home/node/.config/opencode \
             /home/node/.cache \
             /home/node/.claude \
    && chown -R node:node /home/node/.local /home/node/.config /home/node/.cache /home/node/.claude
