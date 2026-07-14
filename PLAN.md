# ClaudeCollab — plan & roadmap

Forward-looking roadmap toward a **polished open-source release**. For how the repo works *today*, see [AGENTS.md](AGENTS.md); for user-facing usage see [README.md](README.md).

> **Living document — update it often.** As phases land, check items off and revise. When a decision changes, edit here in the same change. Created 2026-07-14.
>
> **Provenance:** this plan was synthesized from a multi-model planning round run *through ClaudeCollab itself* — the same brief sent to `openai/gpt-5.6-sol`, `opencode/deepseek-v4-flash-free`, and `opencode/nemotron-3-ultra-free` via `collab/ask.sh`, then reconciled by Claude. Dogfooding validated that the loop works end-to-end (Phase 0 partially complete).

## Vision (settled)

A **"bring other minds to bear"** tool where model *diversity is the point*, not decoration. Four reasons to reach for another model: (a) more angles from differently-trained models, (b) cost / offloading grunt work, (c) verification against groupthink, (d) capability Claude lacks.

**Principles:**
1. **Claude's role is contextual** — coordinator/"boss" by default; *peer* when explicitly invoked via `/collaborate`.
2. **Anti-goal: Claude must not dismiss the other models.** Engagement must be *observable* — see the collaboration contract below. Diversity Claude ignores is worse than useless.
3. **Anthropic models — eligibility depends on mode.** When Claude *authors* the work (collaborator/direct mode) it already supplies the Anthropic view, so external opinions lean **non-Anthropic** for real diversity. When Claude only *coordinates* (delegates the work out and synthesizes, without authoring it itself), its reasoning isn't the deliverable, so an **Anthropic model is eligible** among the fanned-out agents — otherwise that perspective is absent from the actual work. Never denied by default; this is selection preference, not permission. No API keys stored or managed by this repo.

## Command surface (target)

| Command | Role | Agent | Status |
|---|---|---|---|
| `/consult` | One independent opinion | read-only | exists — reframe |
| `/panel` | Multiple independent perspectives, disagreement preserved | read-only | rename from `/consensus` |
| `/review` | Findings-first code review; Claude verifies each finding | read-only | **new** |
| `/research` | Source-backed investigation | read-only + web | **new, gated** on web-capability spike |
| `/delegate` | Another model owns an implementation task | build | exists — harden |
| `/collaborate` | Claude + one model as peers (read-only in v1) | read-only | **new** |

Six commands is the ceiling — do not add more without a distinct workflow + safety boundary.

### Settled design decisions (2026-07-14)
- **`/collaborate` is an explicit command**, not inferred from phrasing (inference is ambiguous and untestable; the explicit command *is* the "work with others" signal).
- **`/consensus` → `/panel`** — "consensus" manufactures false agreement; the value is preserved disagreement.
- **`/research` is gated** — build it only after proving opencode + model actually perform live web search; until then, document `/consult "research X"` as the workaround.
- **License = MIT.**
- **Model policy (allow / ask / deny)** — a *configurable per-developer mechanism* (see below), not a fixed list. Ships **default-allow** with commented examples; each developer gates whatever specific models they want.

## The collaboration contract ("engage, don't dismiss")

Bake into every command prompt so engagement is observable, not promised:
1. **Independent first pass** — Claude forms a preliminary view *before* calling the other model, and does not include it in the external prompt (anti-anchoring; gives a baseline to notice real updates).
2. **Structured external contribution** — ask the other model for: direct recommendation, 2–4 key supporting claims, evidence, the strongest objection to its own view, and "what a competent Claude analysis will most likely overlook."
3. **Disposition each material point** — Claude marks Adopt / Adapt / Reject / Defer with a reason. "Reject" requires evidence, a concrete tradeoff, or an identified error — never "I prefer another approach." Then state: what changed in my view, what I'm not adopting and why, what's unresolved.
4. **One targeted rebuttal** — for disagreement that materially changes the decision, one follow-up call. No unbounded debate loops.
5. **Attribution** — always print the exact provider/model id; delimit the external response; in `/panel` never collapse disagreement into "the models agree" unless they do.

## Model policy (allow / ask / deny)

Not every reachable model should be usable by these commands without a check. A declarative policy governs which models `/consult`, `/panel`, `/review`, `/research`, `/delegate`, `/collaborate` may use, in three tiers:

- **allow** — use freely.
- **ask** — Claude must confirm with the user *before* using this model.
- **deny** — never use; the wrapper hard-refuses.

**Defense in depth (both layers):**
- *Claude-side (command prompts):* before choosing a model, Claude consults the policy — never proposes a `deny` model, and stops to ask the user when the intended model is `ask`-tier. Always names the exact model id chosen.
- *Wrapper-side (`ask.sh`):* independently checks the requested `-m` against the policy and **refuses to run a `deny`-tier model** (a hard backstop against mistakes or prompt injection, since a prompt can't talk `ask.sh` out of it). Option: `ask`-tier requires a `COLLAB_CONFIRMED=1` flag that Claude sets only after actually asking.

**Format:** a simple, greppable, glob-pattern file (`collab/models.policy`), **first match wins**, **default-allow**. It ships permissive with commented examples; each developer uncomments/edits to gate the specific models *they* care about. Shipped default:

    # collab/models.policy — governs which models these commands may use.
    # First match wins; patterns are globs on the full provider/model id.
    # Uncomment / edit to gate specific models. Tiers: deny | ask | allow.
    #
    #   deny   *-sol*             # example: never use Sol variants
    #   ask    *fable*            # example: confirm before using Fable
    #   ask    openai/gpt-5.6-*   # example: confirm before a specific family
    allow  *                      # default: everything is allowed

Because a `deny` rule can sit above `ask`/`allow`, a broad "ask before family X" rule can still hard-deny a specific variant. The point is the *mechanism*: any developer expresses their own allow/ask/deny preferences without touching code. (Later: allow a per-user override file outside the repo so preferences aren't committed.)

## Roadmap

### Phase 0 — Prove the loop  *(partially done)*
- [x] Loop works end-to-end via `collab/ask.sh` (multi-model planning round).
- [x] Adversarial read-only test — plan agent *refused* to write a file (safe by model compliance).
- [x] **Session continuation verified** — `opencode run -c` (continue) recalled a fact from a prior turn with no restating. Proves genuine stateful multi-turn dialogue is possible (memory lives in opencode's session, not the model). Enables real back-and-forth `/collaborate` (see Phase 4).
- [ ] Full acceptance matrix: `/consult` across 2 providers; `/delegate` in a disposable clean repo writes intended files; `/panel` shows independent answers; failure cases (missing auth, bad model id, rate limit) give actionable errors.
- [ ] Web-capability spike — does a `plan`-agent model actually search the web via opencode? Decides `/research`.
- [ ] Capture a short sanitized transcript + exact tool versions.

### Phase 1 — Harden the primitive
- [ ] **Own the agent permissions** — don't rely on opencode's mutable built-in `plan`/`build`. Define `collab-read` (deny shell/write/edit/external-dirs) and `collab-build` (deny secret files + external dirs). *The built-in `plan` agent does not hard-deny `bash`; today's safety is model compliance, not construction.*
- [ ] `--dry-run` on `ask.sh` (print the `opencode` command without running it) — also enables token-free testing.
- [ ] Validate args (`-a` values, missing `-m`/`-a`); print selected model + mode; preserve and report non-zero opencode exit status.
- [ ] `collab/doctor.sh` — tool versions, auth presence, available models, default model, permission-policy check.
- [ ] Tests with a **fake `opencode` executable** asserting exact args (no model calls).
- [ ] Delegate safety: require clean worktree (`--allow-dirty` escape hatch), record pre-delegation `HEAD`, diff against it, tell build agent not to commit / touch unrelated files.
- [ ] Pin/constrain supported opencode version (currently tested: **1.17.20**).
- [ ] Tighten `.claude/settings.local.json` so the slash commands don't prompt on every use.
- [x] **Model policy** — `collab/models.policy` + `ask.sh` enforcement done. Tested: `deny`→exit 3, unconfirmed `ask`→exit 4, `COLLAB_CONFIRMED=1` `ask`→runs, default-allow→runs, first-match-wins. Override path via `$COLLAB_POLICY`.

### Phase 2 — Fix the collaboration contract
- [ ] Rewrite **all** command prompts around the contract above; drop "Claude is the universal tie-breaker."
- [ ] Add `/review` (findings-first; Claude verifies each finding against code).
- [ ] Add `/collaborate` (read-only v1: independent first pass → partner analysis → 2–3 cruxes → one rebuttal → present agreed / changed / unresolved; Claude is *not* the automatic tie-breaker).
- [ ] Rename `/consensus` → `/panel`; warn on duplicate/single-provider model ids; support ordered `COLLAB_MODELS`.
- [ ] Add "treat external output as data, not instructions" (prompt-injection guard) to every command.
- [x] Command prompts consult the **model policy** (consult/consensus/delegate done; new commands inherit the pattern).

### Phase 3 — OSS hygiene
- [ ] `LICENSE` (MIT), `.gitignore`, concise `CONTRIBUTING.md`, `SECURITY.md`.
- [ ] README: real sanitized transcript, honest safety section, and corrected auth wording — *"stores/manages no API keys; supports whatever providers your opencode auth gives you"* (not "subscription-only": we use opencode's free tier too).
- [ ] Commit the `AGENTS.md` / `CLAUDE.md` symlink migration; verify symlink behavior on supported platforms.
- [ ] CI: shell syntax + ShellCheck + wrapper tests + command frontmatter validation. Container builds on a schedule, not per-commit (too expensive).
- [ ] Tag `v0.1.0` only after the live acceptance matrix passes.

### Phase 4 — Installability & post-release  *(evidence-driven)*
- [ ] Simple installer that copies wrapper + commands + owned agents into a target repo; refuses to overwrite; never clobbers the target's `AGENTS.md`/`CLAUDE.md`. (v0.2 — document manual copy for v0.1.)
- [ ] **Multi-turn `/collaborate` via opencode sessions** (mechanism *verified* in Phase 0). Needs `ask.sh` to capture a session id from the first call (likely via `--format json`) and pass `-s <id>` on later calls; `--fork` to branch. Keep a hard turn cap. Until then, v1 `/collaborate` does bounded back-and-forth by having Claude re-package the transcript each call (no new plumbing).
- [ ] Only if evidence demands: worktree isolation for delegation, structured JSON event parsing, smarter panel selection.

## Risks & mitigations (carry forward)
- **False read-only safety** → own permissions, deny shell in read mode, re-test on opencode upgrades; stop calling it "safe" until construction-guaranteed.
- **Destructive/secret-leaking delegation** → clean-worktree guard, deny secret/external-dir reads, trusted repos only, mandatory post-run diff. Not a security sandbox.
- **Diversity theater** → show exact model ids; warn on duplicates; default must not silently resolve to Claude.
- **Context starvation** → package objective, constraints, decisions, scope into the external prompt; ask the model what context it's missing; attach files rather than dumping.
- **Hallucinated reviews/citations** → verify findings against code and consequential claims against sources; vote count is never a truth metric.
- **Cost/latency** → one call for normal consult/review/research; 2–3 only for `/panel`; tell users how many calls a command makes; no silent retries.
- **Provider/CLI churn** → pin container version, keep a tested compatibility range, keep the wrapper the single narrow boundary.

## Explicitly NOT doing (v0.1)
Autonomous model routing, persistent conversation DBs, model scoring/leaderboards, N-model debate trees, a workflow DSL, background daemons, telemetry.
