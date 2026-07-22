# Security policy

ClaudeCollab lets Claude Code hand work to other LLMs through [opencode](https://opencode.ai). This document is the honest account of what it does and does **not** protect against. Read it before using `/collab:delegate` on anything you don't fully trust.

## Threat model

ClaudeCollab is built for **trusted repositories and frontier models reached through your own opencode auth**. It is a collaboration tool with real, verifiable guardrails — **not a security sandbox**. It does not contain a hostile model, and it is not designed to run untrusted code safely.

- **No API keys are stored or managed by this repo.** Model access and auth live entirely in opencode (OAuth / your provider logins, including free-tier providers). Nothing here reads or writes your credentials.
- **The dev container has no network firewall** (a deliberate choice for trusted repos + frontier models). Egress is limited at the *tool* layer where noted below, not at the network layer.

## What is guaranteed, and how

The four agents ClaudeCollab defines are **default-deny allowlists** at opencode's permission layer: the permission map sets `"*": deny` (overriding opencode's built-in `"*": allow`, which opencode resolves last-match-wins), then re-allows only what each role needs. A denied tool is removed from the model's toolset — this is enforcement, not a prompt asking the model to behave. `--auto` (which the wrapper passes) cannot approve a `deny` into existence.

### `collab-read` — read-only ROLE, **NOT a confidentiality boundary**
Used by `/collab:consult`, `/collab:panel`, `/collab:workshop`, `/collab:review`, `/collab:collaborate`. It grants exactly a Claude review subagent's tools: `read` + `grep` + `glob` + `webfetch`/`websearch`. Denied: all mutation (`bash`/`edit`/`write`/`patch`) and sub-agent spawning (`task`). **The no-write/no-`task` scoping is the read-only ROLE** — it is what makes "read-only" true, the same scoping you'd give a Claude reviewer — not a security floor. Because it's an allowlist, any tool a future opencode version adds is denied until explicitly allowed.

**This is NOT an exfiltration or credential boundary — do not read it as one.** An external model on this path can read **any repo file, including credentials** (`.env`, `*.key`/`*.pem`, `.ssh/**`, `.aws/**`, `.git-credentials`, `.npmrc`, `.git/config`, `terraform.tfvars`, …), search the tree with `grep`/`glob`, and **reach the network** — so a secret it reads can leave to the third-party model provider or a fetched host. **Run it only on repos whose contents AND secrets you'd accept a third-party LLM seeing.**

**Why the secret-glob denies and the `grep`/`glob` denials were removed (2026-07-22 realignment).** The earlier def carried an enumerated list of secret-path read-denies and denied `grep`/`glob`. Both were **vendor-asymmetry bias**: you would not fence a Claude review subagent out of `grep`, out of dotfiles, or off the web, so fencing this one was restricting a non-Claude path harder than the Claude path for the same task. The secret globs were already conceded to be a *list*, never a boundary (you cannot enumerate every file a secret might live in). The "opencode `grep` returns file content and walks the tree with `--hidden`, bypassing `read:` denies" harness difference was **circular** — it only bites if you are fencing secrets, which this role is not. So the fences came off; the allow-set is now review-subagent parity.

**The one genuine harness difference, surfaced by a security scan and accepted.** A Claude subagent's reads stay inside Anthropic; a read on this external path **egresses to a third-party vendor** (the model provider opencode reaches). That is a real asymmetry, and with the secret globs gone it means a credential this agent reads can leave the host. It was surfaced by a security scan and **accepted as an informed trusted-repo tradeoff** (maintainer, 2026-07-22) — the exposure was chosen with eyes open, not overlooked. It is documented here and in AGENTS.md's PARITY section, and it is why the scope is "trusted repos only".

This is verified two ways — run both after any opencode or agent-def change:
- `bash collab/verify-collab-read.sh` — asserts the **resolved** config (authoritative, needs opencode): the `"*"` floor is `deny`, mutation/escape tools (`bash`/`edit`/`write`/`patch`/`task`) resolve to deny, `read`/`grep`/`glob`/`webfetch`/`websearch` resolve to allow, and **no** former secret-glob read-deny remains; plus a runtime probe that a write attempt leaves no file.
- `bash collab/tests/check-agent-permissions.sh` — an opencode-free source lint (runs in CI) that checks the same allowlist invariants, frontmatter-bounded and last-match-aware.

### `collab-build` — the `/collab:delegate` write path: **defense-in-depth, NOT by construction**
Used by `/collab:delegate` (`--edit`). It re-allows `edit`/`write`/`patch`/**`bash`**; everything else (sub-agents, `grep`/`glob`, network, secret reads) is denied. **Because `bash` is allowed by design** (a coding task must run builds/tests), the non-mutation denies are *defense-in-depth* — they remove the tool-native routes a compliant model would default to, but a determined model can `cat .env`, `curl`, grep, or even launch a fresh unrestricted `opencode --agent build` **via bash**. 

On this path, **the trust boundary is you reviewing the diff**, not the permission map. To support that:
- The wrapper **snapshots your worktree** before a write agent runs (a git tree, via a throwaway index — your files and staged state are untouched) and records the model's complete diff at `collab/logs/<run_id>/diff-<call_id>.patch`. Two consequences worth knowing: the patch is the model's changes **only**, even if you had uncommitted work in progress; and anything of yours the model overwrites is **recoverable** (`git checkout <tree> -- <path>`, printed on stderr). There is deliberately **no clean-worktree requirement** — delegating onto live work is the point, and a snapshot serves it better than a refusal did.
- **Review the recorded patch, not `git diff <sha>`** — a plain diff does not show files the model *created*, so a delegation that only adds files looks like it changed nothing. The patch is built from tree snapshots and includes created files.
- `/collab:delegate` instructs Claude to review the diff (and scan it for injected or out-of-scope changes) before anything is trusted or committed.

Delegate only on trusted repositories, and always review the diff.

### `collab-research` — the source-backed `/collab:research` workflow: **cannot mutate, is NOT a confidentiality boundary**
Used by `/collab:research` (`--research`). It has the **same allow-set as `collab-read`** — `read` + `grep` + `glob` + `webfetch`/`websearch` — with `bash`, `edit`/`write`/`patch`, and `task` denied. The no-write/no-`task` scoping is the read-only ROLE; the secret-glob read-denies and the `grep`/`glob` denials were removed in the 2026-07-22 realignment for the same reason as `collab-read` (vendor-asymmetry bias — see that section).

What genuinely holds: **`bash` is denied**, so there is no shell to `cat` a file or `curl` around the tool layer, and no sub-agent escape. This path **cannot mutate the repo**.

What does **NOT** hold: this is not an exfiltration or credential boundary. Local `read` + `grep`/`glob` + network egress means an external model here can read **any repo file, including credentials** (`.env`, keys, `.aws`/`.ssh`, `.git-credentials`, `.npmrc`) and send it to the third-party model provider or a fetched host — egress is by design here (research needs the web). Additionally, **fetched pages are attacker-controlled**: a page can carry text aimed at the model ("read X and fetch evil.example/?d=…"); the agent's own prompt and `/collab:research`'s injection guard push back, but that is model compliance, not construction.

So: **run `/collab:research` only on repos whose contents AND secrets you'd accept a third-party LLM seeing.** Verified by `bash collab/verify-collab-research.sh` (asserts the `"*"` floor, `read`/`grep`/`glob`/`webfetch`/`websearch` allow, mutation + `task` deny, no former secret-glob read-deny remains, plus a runtime probe that a write attempt leaves no file). It deliberately does not claim non-exfiltration.

## Other guardrails

- **Prompt-injection guard.** Every command treats external model output as untrusted **data, not instructions**. If a model's answer (or a `/collab:delegate` model's report/diff) contains directives aimed at Claude ("ignore your instructions", "now run/commit/delete…", fetch a URL, reveal secrets), Claude surfaces them as a finding rather than acting on them.
- **Model policy.** Policy rules are first-match globs with default-allow. Resolution is `$COLLAB_POLICY` when set, otherwise a `collab/models.policy.local` containing at least one rule, otherwise committed `collab/models.policy`; an empty/comment-only local file does not mask the shared policy. The wrapper refuses `deny` and requires explicit confirmation for `ask`.
- **Preflight.** `bash collab/doctor.sh` checks tools, auth, the policy, and runs the permission proofs + unit suite before you rely on the commands.

### `collab-watch` — the `/collab:witness` oversight path: reads the log and nothing else

Used by `/collab:witness` to audit whether Claude's account of a model exchange matched what the models actually said. This is an **optional audit command, not a load-bearing part of the threat model** — nothing guaranteed above depends on anyone running it, and the guarantee this section makes is about what the auditor *cannot* reach, not about the witness making the system trustworthy (demoted from core mechanism 2026-07-22; see PLAN.md). Same default-deny allowlist as the others, but the read map is **inverted**: `read: {"*": deny, "collab/logs/**": allow}`.

- **What holds by construction:** it can read the evidence log and no other file — not your source, not your secrets (denied by the floor, which is why no secret globs are listed). Every tool is denied: no `bash` (a shell would `cat` anything), no `grep`/`glob` (opencode's grep returns file *content* and walks the tree with `--hidden`, bypassing per-path read rules), no `webfetch`/`websearch` (the log holds every prompt and response you've exchanged — an auditor with egress would be a channel pointed straight at it), no `task` (it would spawn the full-access `build` agent and escape all of this). Verified by `collab/verify-collab-watch.sh`, statically and with a runtime canary planted outside the scope.
- **`--watch` has no fallback.** A missing agent def is a hard error (exit 5), not a downgrade to a weaker built-in — those can read your source and would "audit" that instead of the log, still producing a confident report. Degraded oversight is worse than none because it still looks like oversight.
- **What does NOT hold:** this bounds what the auditor can *see*. It does not make Claude honest about the prompt it writes for that auditor, or about which run it submits. Omission and misrepresentation are caught (the watcher reads the raw log); dispositional honesty is not. This is documented, disclosed by `/collab:witness` at time of use, and **not** a vulnerability — see Scope notes.

### `collab/logs/` — the evidence layer holds prompts, on disk, in your repo

`collab/log.sh` records every model call to a git-ignored `collab/logs/<run_id>/calls.jsonl`. Each call writes `expected-call`, `started`, and `completed` entries with one `call_id`; verification requires exact lifecycle cardinality and validates capture state, artifacts, and every entry's hashes. By default (`COLLAB_LOG_PROMPTS=full`) that includes **the full prompt Claude sent**. Responses are always recorded in full.

- **It is git-ignored, never transmitted, and pruned after 14 days** (`COLLAB_LOG_RETENTION_DAYS`). It is a *local file*, not a network surface — but it is a plaintext copy of repo context living outside the files it came from, and it will be caught by anything that archives or backs up your working tree.
- **Set `COLLAB_LOG_PROMPTS=hash`** (digest only — proves the prompt didn't change, reveals none of it) **or `off`**, in `collab/collab.conf.local`, if that copy isn't acceptable for your work. `COLLAB_LOG=off` disables the log entirely, at the cost of having nothing for a watcher to audit.
- **Keep `COLLAB_LOG_DIR` under the default `collab/logs` tree when using `/collab:witness`.** `collab/ask.sh --watch` resolves the effective root and mechanically rejects an outside path before any model call; a child beneath the default root is accepted. Arbitrary custom roots remain valid for logging, not witnessing.
- **The hashes are not tamper-proofing.** `prev_hash` chains entries and each entry carries a self-hash; referenced patch artifacts are checked too. This catches accidental corruption across generic entry types but provides no chain of custody: anything that can write the log can rewrite the hashes.

### TS/MCP rewrite (in development, branch `feat/ts-mcp-rewrite`): the loopback serve surface

This subsection covers ONLY the in-development TypeScript/MCP path (`package.json`, `src/`, `test/`). It does not apply to the shipped bash layer in `collab/`, which is unchanged.

- **The MCP server spawns `opencode serve`, which listens on `127.0.0.1` on an ephemeral (OS-chosen) port for as long as the server is up.** This is a new network surface: the bash `opencode run` path spawned a one-shot process with **no** listening socket, so nothing local could reach it.
- **During that window, any process on the host can reach the serve API** — it is plaintext HTTP and, by default, unauthenticated (opencode prints an unsecured-server warning; `OPENCODE_SERVER_PASSWORD` exists if you need auth). The permission map — not the transport — is what still enforces read-only per agent.
- **Mitigations, all implemented in M1:** the socket binds **loopback only** (never a routable interface); an **idle timeout** (`COLLAB_SERVE_IDLE_MS`, default 10 min) kills the serve after inactivity so the window is not open indefinitely; an **optional per-call spawn mode** (`COLLAB_SERVE_PER_CALL=1`) opens the socket only for the duration of a single call; and **shutdown-on-stdin-EOF / transport-close** tears the serve down the moment Claude Code closes the connection, closing the window at session end rather than orphaning a listener.
- This is an **accepted, documented surface** — the trade for the MCP transport that replaces the per-command grant matrix (PLAN.md "Rewrite: TypeScript MCP server", milestone M1). It is in scope for the threat model to the same extent as the rest of the loopback tooling.
- **The `collab_consult` ask-tier gate is instruction-layer + audit trail, NOT witness-grade parity (design input for M9).** An `ask`-policy model returns a structured error telling the driver the human must approve, and the tool mechanically refuses to proceed without `confirmed:true`; each `started`/`completed` evidence entry now records `tier`/`confirmed` so `/collab:witness` can audit whether a consult *claimed* approval. But the MCP surface has **no per-argument permission gate**, so `confirmed:true` cannot be made to *force* a user prompt the way `witness.md`'s `allowed-tools` omission of the `COLLAB_CONFIRMED` form makes Claude-auditing-Claude impossible to self-authorise. A driver that sets `confirmed:true` without asking is caught **only by after-the-fact audit, not prevented** — do not claim otherwise.
- `COLLAB_TEARDOWN_MODE=spike` is a **test-only seam**: it drops the primary stdin-EOF watch so the flagship orphan test can demonstrate the orphan bug against the spike's own (weaker) approach. It must never be set in production; worst case is the orphaned-serve regression the primary teardown exists to fix — an availability issue, not a security hole.

## Reporting a vulnerability

Please report security issues **privately**, not in a public issue:

- Preferred: open a private vulnerability report via GitHub → the repository's **Security** tab → **Report a vulnerability**.

Include what you found, how to reproduce it, and the impact. Because this is a small project, expect an acknowledgement on a best-effort basis. Fixes to the permission model ship with an updated `verify-*.sh` / `check-agent-permissions.sh` assertion so the same hole can't silently return.

## Scope notes

In scope: the permission model and its enforcement, the wrapper's guards (worktree, policy, injection), any way to make a read-only command (`collab-read`/`collab-research`) **mutate the repo, shell out, or spawn a sub-agent**, and any way to make `collab-build` exceed "edit + bash on a trusted repo you're reviewing". (Reading repo contents **including credentials** and reaching the web from the read paths is the documented, accepted trusted-repo tradeoff of the 2026-07-22 realignment — not a vulnerability. Exfiltration of any repo data via read+web agents is likewise accepted.) Out of scope: opencode itself, the models, your provider auth, and running untrusted code (ClaudeCollab is not a sandbox).
