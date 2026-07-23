@AGENTS.md

# Claude-Specific Instructions

**`AGENTS.md` governs, and every rule in it applies to Claude in full.** It carries the parity rules, the vendor-is-not-a-threat-model posture, provenance, capability cost, and the untrusted-external-output rule. Those are **deliberately not restated here.** Claude reads them through the `@AGENTS.md` import above, so a second copy adds emphasis and no information — while drifting from the original the moment either is edited. That is not hypothetical: an earlier version of this file restated the parity question in wording that had already diverged from `AGENTS.md`'s, on the day it shipped. `AGENTS.md` records the detail; it is deliberately not re-quoted here. **This file adds only what `AGENTS.md` does not say.**

## Before finalizing

- Prefer evidence over intuition or model consensus. If a claim about opencode, Claude Code, permissions, or command naming can be tested locally, test it.
- Run a **Bias Audit** on changes touching agent permissions, model selection, command prompts, wrapper policy, or security docs: parity question answered, capability cost stated, provenance recorded, harness difference named if asymmetric, and external-model disagreement preserved or explicitly rejected with evidence. The rules being audited live in `AGENTS.md` under Conventions → PARITY; this is the procedure, not a second copy of them.

## When another model has spoken

- Verify each consequential claim against the repo or its cited source before reporting it as confirmed.
- Preserve disagreement. If you reject a model's point, say why in concrete terms: code evidence, test result, project constraint, or user preference. Do not hide a material disagreement or an open uncertainty behind "addressed feedback" or "validated the change" — say what was confirmed, refuted, or left uncertain.

## Documentation Discipline

- Keep shared behavior in `AGENTS.md`; keep only Claude-specific behavior here. If a rule would apply to a delegated model too, it belongs in `AGENTS.md` — not both.
- If this file changes the relationship between Claude and delegated models, update `AGENTS.md` and the tests in the same change.
- **The `CLAUDE.md`/`AGENTS.md` relationship is no longer machine-checked.** The bash `doctor.sh` that enforced the four-guardrail set and the 60-line anti-fork ceiling retired with the rest of the bash layer (M12), and `modelguild doctor` does not check this repo-internal invariant. Keeping this file a thin pointer that restates nothing from `AGENTS.md` is now a discipline, not a guarded construction — hold it by hand.
