/**
 * Config & model-resolution port tests (PLAN.md M4; CONTRACT.md area B, C8–C14) — OFFLINE.
 *
 * `conf_get` byte-identity (C11) is held by REUSE — `config.ts` re-exports `log.ts`'s
 * `confGet`, so there is one parser. We re-pin the run-tests.sh footgun cases here
 * anyway. Panel resolution (C13/C14) is additionally cross-checked against the real
 * `collab/panel-models.sh` (which prints the resolved list to stdout, exit 2 on none):
 * for a corpus of arg/env/conf inputs the TS model list and exit intent must match the
 * bash oracle's. No model is called.
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  confGet,
  resolveModel,
  checkResolvedModelId,
  resolveCollabRoot,
  candidateRoots,
  resolveConfFile,
  readConfContents,
  resolvePanelModels,
} from "../src/config.js";
import { Checker, repoRoot } from "./harness.js";

const PANEL = path.join(repoRoot, "collab", "panel-models.sh");

const tmpDirs: string[] = [];
function tmp(prefix = "m4cfg-"): string {
  const d = mkdtempSync(path.join(tmpdir(), prefix));
  tmpDirs.push(d);
  return d;
}
function cleanup(): void {
  for (const d of tmpDirs) { try { rmSync(d, { recursive: true, force: true }); } catch { /* noop */ } }
}

/** Run panel-models.sh; return the resolved model list (stdout) + exit code. */
function panelOracle(args: string[], extraEnv: Record<string, string> = {}): { models: string[]; code: number } {
  const env = { ...process.env } as NodeJS.ProcessEnv;
  for (const k of ["COLLAB_MODELS", "COLLAB_CONF", "COLLAB_MODEL", "COLLAB_POLICY"]) delete env[k];
  Object.assign(env, extraEnv);
  const r = spawnSync("bash", [PANEL, ...args], { env, encoding: "utf8" });
  const models = (r.stdout ?? "").split("\n").filter((l) => l.length > 0);
  return { models, code: r.status ?? -1 };
}

export async function run(): Promise<number> {
  const t = new Checker();

  try {
    // ---- conf_get (C10/C11), re-pinning run-tests.sh 21b et al. -----------------
    t.check(confGet("COLLAB_MODEL=openai/gpt-5\n", "COLLAB_MODEL") === "openai/gpt-5",
      "confGet: plain KEY=value");
    t.check(confGet("COLLAB_MODEL=openai/commented   # my default\n", "COLLAB_MODEL") === "openai/commented",
      "confGet: inline '# comment' stripped (run-tests 21b)");
    t.check(confGet('COLLAB_MODEL="openai/quoted"\n', "COLLAB_MODEL") === "openai/quoted",
      "confGet: one layer of double quotes stripped");
    t.check(confGet("COLLAB_MODEL=openai/a\nCOLLAB_MODEL=openai/b\n", "COLLAB_MODEL") === "openai/b",
      "confGet: last assignment wins");
    t.check(confGet("   COLLAB_MODEL = openai/x\n", "COLLAB_MODEL") === "openai/x",
      "confGet: leading whitespace + spaces around key/value tolerated");
    t.check(confGet("# COLLAB_MODEL=nope\n", "COLLAB_MODEL") === "",
      "confGet: commented line ignored");
    t.check(confGet("", "COLLAB_MODEL") === "", "confGet: absent key → empty");

    // ---- resolveModel precedence (C8): flag > env > conf > "" -------------------
    const conf = "COLLAB_MODEL=openai/from-conf\n";
    t.check(resolveModel({ flag: "openai/from-flag", env: { COLLAB_MODEL: "openai/from-env" } as NodeJS.ProcessEnv, confContents: conf }) === "openai/from-flag",
      "resolveModel: -m flag wins");
    t.check(resolveModel({ env: { COLLAB_MODEL: "openai/from-env" } as NodeJS.ProcessEnv, confContents: conf }) === "openai/from-env",
      "resolveModel: $COLLAB_MODEL over conf (run-tests 21)");
    t.check(resolveModel({ env: {} as NodeJS.ProcessEnv, confContents: conf }) === "openai/from-conf",
      "resolveModel: conf file supplies default (run-tests 21)");
    t.check(resolveModel({ env: {} as NodeJS.ProcessEnv, confContents: "" }) === "",
      "resolveModel: nothing set → empty (opencode default)");

    // ---- leading-dash guard (C12) ----------------------------------------------
    const bad = checkResolvedModelId("--print-logs");
    t.check(bad.ok === false && bad.exitCode === 2,
      "checkResolvedModelId: leading-dash id refused with exit 2 (run-tests 21c)");
    t.check(checkResolvedModelId("openai/gpt-5").ok === true,
      "checkResolvedModelId: normal id ok");

    // ---- collab-root resolution (M4 order: env > project > home) ----------------
    {
      const projBase = tmp();
      mkdirSync(path.join(projBase, "collab"), { recursive: true });
      const home = tmp();
      const r1 = resolveCollabRoot({ COLLAB_ROOT: "/explicit/root" } as NodeJS.ProcessEnv, projBase, home);
      t.check(r1.source === "env" && r1.root === "/explicit/root", "collab-root: $COLLAB_ROOT wins");
      const r2 = resolveCollabRoot({} as NodeJS.ProcessEnv, projBase, home);
      t.check(r2.source === "project" && r2.root === path.join(projBase, "collab"),
        "collab-root: project ./collab/ when it exists");
      const noProj = tmp();
      const r3 = resolveCollabRoot({} as NodeJS.ProcessEnv, noProj, home);
      t.check(r3.source === "home" && r3.root === path.join(home, ".claude", "collab"),
        "collab-root: ~/.claude/collab fallback");
      // conflict detection for doctor
      const cands = candidateRoots({ COLLAB_ROOT: "/x" } as NodeJS.ProcessEnv, projBase, home);
      t.check(cands.length >= 2 && cands[0].source === "env" && cands.some((c) => c.source === "project"),
        "candidateRoots: reports overlapping roots for doctor conflict warning");
    }

    // ---- config-file resolution (C9) -------------------------------------------
    {
      const root = tmp();
      mkdirSync(root, { recursive: true });
      writeFileSync(path.join(root, "collab.conf.local"), "COLLAB_MODEL=openai/local\n");
      t.check(resolveConfFile(root, {})?.endsWith("collab.conf.local") === true,
        "resolveConfFile: <root>/collab.conf.local when present");
      t.check(resolveConfFile(root, { COLLAB_CONF: "/custom/conf" } as NodeJS.ProcessEnv) === "/custom/conf",
        "resolveConfFile: $COLLAB_CONF overrides");
      t.check(readConfContents(root, {}).includes("openai/local"),
        "readConfContents: reads the resolved file");
      t.check(readConfContents(tmp(), {}) === "", "readConfContents: missing file → empty string");
    }

    // ---- panel unit assertions (C13/C14) ---------------------------------------
    {
      const twoProv = resolvePanelModels({ args: ["openai/gpt-5", "google/gemini-2.5-pro"] });
      t.check(twoProv.models.length === 2 && twoProv.warnings.length === 0,
        "panel: two cross-provider models, no warnings");
      const dup = resolvePanelModels({ args: ["openai/gpt-5", "openai/gpt-5"] });
      t.check(dup.models.length === 1 && dup.warnings.some((w) => /duplicate/.test(w)),
        "panel: duplicate dropped + warned, first-seen order kept");
      const single = resolvePanelModels({ args: ["openai/gpt-5", "openai/gpt-5-mini"] });
      t.check(single.warnings.some((w) => /single-family|diversity theater/.test(w)),
        "panel: single-provider set warns (diversity theater)");
      const one = resolvePanelModels({ args: ["openai/gpt-5"] });
      t.check(one.models.length === 1 && one.warnings.some((w) => /only 1 model/.test(w)),
        "panel: <2 distinct models warns");
      const badTok = resolvePanelModels({ args: ["justname", "openai/gpt-5"] });
      t.check(badTok.models.length === 2 && badTok.warnings.some((w) => /doesn't look like/.test(w)),
        "panel: bad token warned but still kept");
      const none = resolvePanelModels({ args: [], env: {} as NodeJS.ProcessEnv, confContents: "" });
      t.check(none.models.length === 0 && none.exitCode === 2,
        "panel: no models → exit-2 intent");
      const commas = resolvePanelModels({ args: ["openai/a,google/b, opencode/c"] });
      t.check(commas.models.join(",") === "openai/a,google/b,opencode/c",
        "panel: comma/space separated, order preserved");
    }

    // ---- panel precedence: args > $COLLAB_MODELS env > conf COLLAB_MODELS -------
    {
      const confModels = "COLLAB_MODELS=openai/from-conf google/from-conf\n";
      const fromConf = resolvePanelModels({ args: [], env: {} as NodeJS.ProcessEnv, confContents: confModels });
      t.check(fromConf.models.join(",") === "openai/from-conf,google/from-conf",
        "panel: conf COLLAB_MODELS used when args/env absent");
      const fromEnv = resolvePanelModels({ args: [], env: { COLLAB_MODELS: "openai/env google/env" } as NodeJS.ProcessEnv, confContents: confModels });
      t.check(fromEnv.models.join(",") === "openai/env,google/env", "panel: env overrides conf");
    }

    // ---- FLAGSHIP-style oracle cross-check against panel-models.sh --------------
    interface PCase { args: string[]; env?: Record<string, string>; conf?: string }
    const pcases: PCase[] = [
      { args: ["openai/gpt-5", "google/gemini-2.5-pro"] },
      { args: ["openai/gpt-5", "openai/gpt-5"] },              // dup
      { args: ["openai/gpt-5", "openai/gpt-5-mini"] },         // single provider
      { args: ["openai/gpt-5"] },                              // <2
      { args: ["justname", "openai/gpt-5"] },                  // bad token kept
      { args: ["openai/a,google/b, opencode/c"] },             // comma/space mix
      { args: [], env: {}, conf: "" },                         // none → exit 2
      { args: [], env: { COLLAB_MODELS: "openai/e google/f" } },  // env source
    ];

    let pChecks = 0;
    let pAgree = 0;
    let pMismatch = 0;
    for (const pc of pcases) {
      pChecks += 1;
      const env: Record<string, string> = { ...(pc.env ?? {}) };
      let confContents = "";
      if (pc.conf !== undefined) {
        // Point BOTH bash and TS at the same conf via $COLLAB_CONF.
        const d = tmp("m4pconf-");
        const f = path.join(d, "conf");
        writeFileSync(f, pc.conf);
        env.COLLAB_CONF = f;
        confContents = pc.conf;
      }
      const ts = resolvePanelModels({ args: pc.args, env: env as NodeJS.ProcessEnv, confContents });
      const bash = panelOracle(pc.args, env);
      const listMatch = ts.models.join("\n") === bash.models.join("\n");
      const codeMatch = (ts.exitCode ?? 0) === (bash.code ?? 0);
      if (listMatch && codeMatch) {
        pAgree += 1;
      } else {
        pMismatch += 1;
        t.check(false,
          `panel oracle mismatch: args=${JSON.stringify(pc.args)} ts=[${ts.models.join(",")}]/${ts.exitCode ?? 0} bash=[${bash.models.join(",")}]/${bash.code}`);
      }
    }
    t.check(pMismatch === 0,
      `panel oracle cross-check: ${pAgree}/${pChecks} cases agree (model list + exit), 0 mismatches`);
    console.log(`    [panel oracle corpus] ${pChecks} arg/env/conf cross-checks against panel-models.sh`);
  } finally {
    cleanup();
  }

  console.log(`config.test: ${t.passes} passed, ${t.failures} failed`);
  return t.failures;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  run().then((f) => process.exit(f > 0 ? 1 : 0));
}
