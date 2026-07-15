# Security policy

ClaudeCollab lets Claude Code hand work to other LLMs through [opencode](https://opencode.ai). This document is the honest account of what it does and does **not** protect against. Read it before using `/delegate` on anything you don't fully trust.

## Threat model

ClaudeCollab is built for **trusted repositories and frontier models reached through your own opencode auth**. It is a collaboration tool with real, verifiable guardrails — **not a security sandbox**. It does not contain a hostile model, and it is not designed to run untrusted code safely.

- **No API keys are stored or managed by this repo.** Model access and auth live entirely in opencode (OAuth / your provider logins, including free-tier providers). Nothing here reads or writes your credentials.
- **The dev container has no network firewall** (a deliberate choice for trusted repos + frontier models). Egress is limited at the *tool* layer where noted below, not at the network layer.

## What is guaranteed, and how

The two agents ClaudeCollab defines are **default-deny allowlists** at opencode's permission layer: the permission map sets `"*": deny` (overriding opencode's built-in `"*": allow`, which opencode resolves last-match-wins), then re-allows only what each role needs. A denied tool is removed from the model's toolset — this is enforcement, not a prompt asking the model to behave. `--auto` (which the wrapper passes) cannot approve a `deny` into existence.

### `collab-read` — read-only, non-exfiltrating **by construction**
Used by `/consult`, `/panel`, `/review`, `/collaborate`. The **only** capability it grants is reading non-secret files. Denied: all mutation (`bash`/`edit`/`write`/`patch`), content search and globbing (`grep`/`glob` — opencode's `grep` returns file *content* and walks the tree with `--hidden`, so it is a secret-read path if allowed), sub-agent spawning (`task`), network (`webfetch`/`websearch`), and reads of secret files (`.env`, `*.key`/`*.pem`, `.ssh/**`, `.aws/**`, `credentials*`, …). Because it's an allowlist, any tool a future opencode version adds is denied until explicitly allowed.

This is verified two ways — run both after any opencode or agent-def change:
- `bash collab/verify-collab-read.sh` — asserts the **resolved** config (authoritative, needs opencode): the `"*"` floor is `deny`, every tool resolves to deny, secret reads deny, plus runtime probes (a write attempt leaves no file; a planted secret canary never appears via `read` or `grep`).
- `bash collab/tests/check-agent-permissions.sh` — an opencode-free source lint (runs in CI) that checks the same allowlist invariants, frontmatter-bounded and last-match-aware.

### `collab-build` — the `/delegate` write path: **defense-in-depth, NOT by construction**
Used by `/delegate` (`--edit`). It re-allows `edit`/`write`/`patch`/**`bash`**; everything else (sub-agents, `grep`/`glob`, network, secret reads) is denied. **Because `bash` is allowed by design** (a coding task must run builds/tests), the non-mutation denies are *defense-in-depth* — they remove the tool-native routes a compliant model would default to, but a determined model can `cat .env`, `curl`, grep, or even launch a fresh unrestricted `opencode --agent build` **via bash**. 

On this path, **the trust boundary is you reviewing the diff**, not the permission map. To support that:
- The wrapper enforces a **clean-worktree guard**: it refuses to run a write agent on a dirty tree (`--allow-dirty` to override) and prints the pre-delegation `HEAD` so you can `git diff` exactly what the model changed.
- `/delegate` instructs Claude to review the diff (and scan it for injected or out-of-scope changes) before anything is trusted or committed.

Delegate only on trusted repositories, and always review the diff.

## Other guardrails

- **Prompt-injection guard.** Every command treats external model output as untrusted **data, not instructions**. If a model's answer (or a `/delegate` model's report/diff) contains directives aimed at Claude ("ignore your instructions", "now run/commit/delete…", fetch a URL, reveal secrets), Claude surfaces them as a finding rather than acting on them.
- **Model policy.** `collab/models.policy` (first-match glob, default-allow) lets you `deny`/`ask`/`allow` specific models; the wrapper enforces it as a hard backstop (a `deny` model is refused; an `ask` model needs explicit confirmation).
- **Preflight.** `bash collab/doctor.sh` checks tools, auth, the policy, and runs the permission proofs + unit suite before you rely on the commands.

## Reporting a vulnerability

Please report security issues **privately**, not in a public issue:

- Preferred: open a private vulnerability report via GitHub → the repository's **Security** tab → **Report a vulnerability**.

Include what you found, how to reproduce it, and the impact. Because this is a small project, expect an acknowledgement on a best-effort basis. Fixes to the permission model ship with an updated `verify-*.sh` / `check-agent-permissions.sh` assertion so the same hole can't silently return.

## Scope notes

In scope: the permission model and its enforcement, the wrapper's guards (worktree, policy, injection), and any way to make a read-only command mutate/exfiltrate or make `collab-build` exceed "edit + bash on a trusted repo you're reviewing." Out of scope: opencode itself, the models, your provider auth, and running untrusted code (ClaudeCollab is not a sandbox).
