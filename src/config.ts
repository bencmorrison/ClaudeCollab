/**
 * Config & model resolution port (PLAN.md M4; CONTRACT.md area B, C8–C14).
 *
 * Oracle: `collab/ask.sh` (`conf_get`, default-model precedence, the leading-`-`
 * refusal) and `collab/panel-models.sh` (panel-set resolution + diversity warnings).
 *
 * `conf_get` is deliberately REUSED from `src/log.ts` (`confGet`) rather than
 * re-implemented: C11 requires the parser be byte-identical everywhere it appears, and
 * the surest way to hold that in the TS layer is a single implementation. `log.ts`'s
 * `confGet` already matches `ask.sh`'s awk (leading-ws strip on key, inline `# comment`
 * strip, one layer of surrounding quotes, last-assignment-wins) — verified against the
 * awk source. This module adds only what M4 needs on top: file/root resolution, the
 * default-model precedence chain, the flag-injection guard, and the panel set.
 */

import { existsSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { confGet } from "./log.js";
import { bashGlobMatch } from "./policy.js";

export { confGet };

/* ---------------------------------------------------------------------------
 * Collab-root resolution (PLAN.md M4 npm-server order).
 *
 * The bash scripts resolve their config/policy/log siblings via `dirname "$0"` — the
 * directory of the running script, which for a per-project install is the project's
 * `collab/` and for a global install is `~/.claude/collab/`. The npm server has no
 * such fixed sibling, so it resolves the equivalent root explicitly, in order:
 *     1. `$COLLAB_ROOT`            — explicit override (new in the TS layer; the bash
 *                                    layer has no single root env knob, so this is a
 *                                    documented addition, not a bash behaviour)
 *     2. `<cwd>/collab/`           — a project-local install (the common case)
 *     3. `~/.claude/collab/`       — a global install
 * `source` is exposed so `doctor` can warn when more than one candidate exists (M4:
 * "doctor warns on conflicts").
 *
 * TRUST: `$COLLAB_ROOT` redirects where the policy AND config are read from, so it is a
 * control over the security policy. That grants NO new privilege: it is env-tier,
 * exactly like the already-conceded `$COLLAB_POLICY` — anyone who can set process env
 * can already point policy resolution wherever they like, so redirecting the root is
 * the same authority by another lever, not an escalation. Note the cwd-relative step 2:
 * with no `$COLLAB_ROOT`, the resolved root (hence the active policy) depends on the
 * process's CWD, so the caller must invoke from the intended project. Before M5 wires
 * this into production, `doctor` MUST use `candidateRoots()` to warn when more than one
 * root exists on disk — otherwise a user's policy in one root silently doesn't bind
 * because a different root won (the fail-open class of PLAN.md ~line 91).
 * --------------------------------------------------------------------------- */
export type RootSource = "env" | "project" | "home";

export interface CollabRoot {
  root: string;
  source: RootSource;
}

export function resolveCollabRoot(
  env: NodeJS.ProcessEnv = process.env,
  cwd: string = process.cwd(),
  home: string = os.homedir(),
): CollabRoot {
  const override = env.COLLAB_ROOT;
  if (override && override.length > 0) return { root: override, source: "env" };
  const project = path.join(cwd, "collab");
  if (existsSync(project)) return { root: project, source: "project" };
  return { root: path.join(home, ".claude", "collab"), source: "home" };
}

/**
 * All roots that actually exist, in precedence order — for `doctor` conflict warnings.
 * `$COLLAB_ROOT` is always included (it is an explicit intent even if empty on disk).
 */
export function candidateRoots(
  env: NodeJS.ProcessEnv = process.env,
  cwd: string = process.cwd(),
  home: string = os.homedir(),
): CollabRoot[] {
  const out: CollabRoot[] = [];
  const override = env.COLLAB_ROOT;
  if (override && override.length > 0) out.push({ root: override, source: "env" });
  const project = path.join(cwd, "collab");
  if (existsSync(project)) out.push({ root: project, source: "project" });
  const home2 = path.join(home, ".claude", "collab");
  if (existsSync(home2)) out.push({ root: home2, source: "home" });
  return out;
}

/* ---------------------------------------------------------------------------
 * Agent-def-dir resolution + hardened-def presence (CONTRACT.md C16 lever).
 *
 * bash `ask.sh` computes `agent_def_dir="${COLLAB_AGENT_DIR:-$(conf_get COLLAB_AGENT_DIR)}"`
 * and falls back to the sibling `$(dirname "$0")/../.opencode/agent`, then checks
 * `[ -f "$agent_def_dir/<agent>.md" ]`. The TS server has no fixed sibling, so the
 * "sibling" here is the serve's PROJECT dir (`$COLLAB_PROJECT_DIR` else cwd — the exact
 * value `lifecycle.ts` spawns `opencode serve` from) plus `.opencode/agent`.
 *
 * WHAT THIS ACTUALLY OBSERVES (the honest bound). This is a FILESYSTEM presence check of
 * the def FILE — the same and only lever bash's C16 uses. It does NOT — and cannot —
 * observe opencode's own `--agent` resolution: opencode resolves the agent from ITS OWN
 * config, independently. So if `COLLAB_AGENT_DIR` points somewhere other than where
 * opencode actually resolves defs, this check and opencode can disagree (a caveat bash
 * carries too — AGENTS.md). It governs the tool's refusal decision ONLY, exactly as C16
 * says the bash check governs only the fallback decision.
 * --------------------------------------------------------------------------- */
export function resolveAgentDefDir(opts: {
  env?: NodeJS.ProcessEnv;
  cwd?: string;
  confContents?: string;
}): string {
  const env = opts.env ?? process.env;
  const cwd = opts.cwd ?? process.cwd();
  const override = env.COLLAB_AGENT_DIR;
  if (override && override.length > 0) return override;
  const fromConf = confGet(opts.confContents ?? "", "COLLAB_AGENT_DIR");
  if (fromConf.length > 0) return fromConf;
  // The sibling: the project dir the serve is spawned from (matches lifecycle.ts).
  const projectDir = env.COLLAB_PROJECT_DIR && env.COLLAB_PROJECT_DIR.length > 0
    ? env.COLLAB_PROJECT_DIR
    : cwd;
  return path.join(projectDir, ".opencode", "agent");
}

/** True iff the hardened agent's def file (`<agent>.md`) exists in the resolved dir. */
export function hardenedDefPresent(
  agent: string,
  agentDefDir: string,
): boolean {
  return existsSync(path.join(agentDefDir, `${agent}.md`));
}

/* ---------------------------------------------------------------------------
 * Config-file resolution (C9): `$COLLAB_CONF` if set, else `<root>/collab.conf.local`.
 * Parsed, NEVER sourced.
 * --------------------------------------------------------------------------- */
export function resolveConfFile(
  collabDir: string,
  env: NodeJS.ProcessEnv = process.env,
): string | undefined {
  const override = env.COLLAB_CONF;
  if (override && override.length > 0) return override;
  const local = path.join(collabDir, "collab.conf.local");
  return existsSync(local) ? local : undefined;
}

/** Contents of the resolved config file, or "" when there is none / it is unreadable.
 * (bash `conf_get` short-circuits on a missing file and awk on an unreadable one, both
 * yielding "no value"; an empty string produces exactly that from `confGet`.) */
export function readConfContents(
  collabDir: string,
  env: NodeJS.ProcessEnv = process.env,
): string {
  const file = resolveConfFile(collabDir, env);
  if (!file) return "";
  try { return readFileSync(file, "utf8"); } catch { return ""; }
}

/* ---------------------------------------------------------------------------
 * Default-model precedence (C8): `-m` flag > `$COLLAB_MODEL` env > conf `COLLAB_MODEL`
 * > opencode's own default (empty). `flag` is the value of an explicit `-m`; `undefined`
 * means none was given (an EMPTY `-m` value is a usage error handled by the caller's
 * arg parser, not here).
 * --------------------------------------------------------------------------- */
export function resolveModel(opts: {
  flag?: string;
  env?: NodeJS.ProcessEnv;
  confContents?: string;
}): string {
  if (opts.flag !== undefined && opts.flag !== "") return opts.flag;
  const env = opts.env ?? process.env;
  const fromEnv = env.COLLAB_MODEL;
  if (fromEnv && fromEnv.length > 0) return fromEnv;
  return confGet(opts.confContents ?? "", "COLLAB_MODEL");
}

/**
 * Leading-`-` model-id guard (C12). A model id from env/config bypasses the `-m`
 * `need_arg` check and, if it began with `-`, would be emitted as an unintended
 * opencode flag. bash refuses with exit 2. `source` distinguishes this from the CLI
 * `-m` path (a missing/`-`-leading `-m` VALUE is a usage error, exit 1 — the caller's
 * concern). A resolved model that is safe returns `{ ok: true }`.
 */
export interface ModelIdCheck {
  ok: boolean;
  /** The exit code the bash wrapper would use: 2 for the env/config leading-dash. */
  exitCode?: number;
  reason?: string;
}

export function checkResolvedModelId(model: string): ModelIdCheck {
  if (model.startsWith("-")) {
    return {
      ok: false,
      exitCode: 2,
      reason: `model id '${model}' starts with '-' (from env or config) — refusing to avoid injecting an opencode flag.`,
    };
  }
  return { ok: true };
}

/* ---------------------------------------------------------------------------
 * Panel set resolution (C13/C14) — port of `panel-models.sh`.
 *
 * Precedence: explicit args > `$COLLAB_MODELS` env > conf `COLLAB_MODELS`. Commas OR
 * spaces separate; order is preserved. De-dup keeps first-seen order (each dropped dup
 * warned); warns on <2 distinct models, on an all-one-provider set ("diversity
 * theater"), and on a token that is not `provider/model`. `error` (with exit 2) when no
 * models at all. It does NOT consult the model policy — that is per-call in ask.sh.
 * --------------------------------------------------------------------------- */
export interface PanelResult {
  models: string[];
  warnings: string[];
  /** Present iff no models resolved; the bash exits 2. */
  error?: string;
  exitCode?: number;
}

export function resolvePanelModels(opts: {
  args?: string[];
  env?: NodeJS.ProcessEnv;
  confContents?: string;
}): PanelResult {
  const env = opts.env ?? process.env;
  // Source list in precedence order; `raw="$*"` joins args on a space.
  let raw: string;
  if (opts.args && opts.args.length > 0) raw = opts.args.join(" ");
  else {
    const fromEnv = env.COLLAB_MODELS;
    raw = fromEnv && fromEnv.length > 0 ? fromEnv : confGet(opts.confContents ?? "", "COLLAB_MODELS");
  }
  // Commas → spaces, then split on whitespace, dropping empties (mirrors bash `for m in
  // $raw` under default IFS after `raw="${raw//,/ }"`).
  const tokens = raw.replace(/,/g, " ").split(/\s+/).filter((t) => t.length > 0);

  const warnings: string[] = [];
  const models: string[] = [];
  const seen = new Set<string>();
  for (const m of tokens) {
    if (seen.has(m)) {
      warnings.push(`duplicate model '${m}' dropped (a panel of the same model isn't diverse).`);
      continue;
    }
    // `?*/?*` — provider/model shape. A bad token is WARNED but still kept (bash does
    // not `continue` here).
    if (!bashGlobMatch("?*/?*", m)) {
      warnings.push(`'${m}' doesn't look like a provider/model id — ask.sh/opencode will likely reject it.`);
    }
    seen.add(m);
    models.push(m);
  }

  if (models.length === 0) {
    return {
      models,
      warnings,
      error: "no models. Pass provider/model ids, set COLLAB_MODELS, or add a COLLAB_MODELS= line to collab/collab.conf.local.",
      exitCode: 2,
    };
  }
  if (models.length < 2) {
    warnings.push(`only ${models.length} model resolved — a panel wants 2-3 from different families for genuine diversity.`);
  }
  // provider = `${m%%/*}` (everything before the first `/`).
  const providers = models.map((m) => m.split("/")[0]);
  const distinct = new Set(providers);
  if (models.length >= 2 && distinct.size === 1) {
    warnings.push(`all ${models.length} models are from provider '${providers[0]}' — that's single-family, not cross-provider diversity (risks 'diversity theater').`);
  }
  return { models, warnings };
}
