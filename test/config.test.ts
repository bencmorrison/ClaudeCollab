/**
 * Config & model-resolution port tests (PLAN.md M4; CONTRACT.md area B, C8–C14) — OFFLINE.
 *
 * `conf_get` byte-identity (C11) is held by REUSE — `config.ts` re-exports `log.ts`'s
 * `confGet`, so there is one parser. Panel resolution (C13/C14) is unit-tested directly
 * against `resolvePanelModels` (the reference implementation; the bash `panel-models.sh`
 * oracle it was ported against retired at M12). No model is called.
 */

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
import { Checker } from "./harness.js";

const tmpDirs: string[] = [];
function tmp(prefix = "m4cfg-"): string {
  const d = mkdtempSync(path.join(tmpdir(), prefix));
  tmpDirs.push(d);
  return d;
}
function cleanup(): void {
  for (const d of tmpDirs) { try { rmSync(d, { recursive: true, force: true }); } catch { /* noop */ } }
}

export async function run(): Promise<number> {
  const t = new Checker();

  try {
    // ---- conf_get (C10/C11), re-pinning run-tests.sh 21b et al. -----------------
    t.check(confGet("GUILD_MODEL=openai/gpt-5\n", "GUILD_MODEL") === "openai/gpt-5",
      "confGet: plain KEY=value");
    t.check(confGet("GUILD_MODEL=openai/commented   # my default\n", "GUILD_MODEL") === "openai/commented",
      "confGet: inline '# comment' stripped (run-tests 21b)");
    t.check(confGet('GUILD_MODEL="openai/quoted"\n', "GUILD_MODEL") === "openai/quoted",
      "confGet: one layer of double quotes stripped");
    t.check(confGet("GUILD_MODEL=openai/a\nGUILD_MODEL=openai/b\n", "GUILD_MODEL") === "openai/b",
      "confGet: last assignment wins");
    t.check(confGet("   GUILD_MODEL = openai/x\n", "GUILD_MODEL") === "openai/x",
      "confGet: leading whitespace + spaces around key/value tolerated");
    t.check(confGet("# GUILD_MODEL=nope\n", "GUILD_MODEL") === "",
      "confGet: commented line ignored");
    t.check(confGet("", "GUILD_MODEL") === "", "confGet: absent key → empty");

    // ---- resolveModel precedence (C8): flag > env > conf > "" -------------------
    const conf = "GUILD_MODEL=openai/from-conf\n";
    t.check(resolveModel({ flag: "openai/from-flag", env: { GUILD_MODEL: "openai/from-env" } as NodeJS.ProcessEnv, confContents: conf }) === "openai/from-flag",
      "resolveModel: -m flag wins");
    t.check(resolveModel({ env: { GUILD_MODEL: "openai/from-env" } as NodeJS.ProcessEnv, confContents: conf }) === "openai/from-env",
      "resolveModel: $GUILD_MODEL over conf (run-tests 21)");
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
      mkdirSync(path.join(projBase, "modelguild"), { recursive: true });
      const home = tmp();
      const r1 = resolveCollabRoot({ GUILD_ROOT: "/explicit/root" } as NodeJS.ProcessEnv, projBase, home);
      t.check(r1.source === "env" && r1.root === "/explicit/root", "collab-root: $GUILD_ROOT wins");
      const r2 = resolveCollabRoot({} as NodeJS.ProcessEnv, projBase, home);
      t.check(r2.source === "project" && r2.root === path.join(projBase, "modelguild"),
        "collab-root: project ./modelguild/ when it exists");
      const noProj = tmp();
      const r3 = resolveCollabRoot({} as NodeJS.ProcessEnv, noProj, home);
      t.check(r3.source === "home" && r3.root === path.join(home, ".claude", "modelguild"),
        "collab-root: ~/.claude/modelguild fallback");
      // conflict detection for doctor
      const cands = candidateRoots({ GUILD_ROOT: "/x" } as NodeJS.ProcessEnv, projBase, home);
      t.check(cands.length >= 2 && cands[0].source === "env" && cands.some((c) => c.source === "project"),
        "candidateRoots: reports overlapping roots for doctor conflict warning");
    }

    // ---- config-file resolution (C9) -------------------------------------------
    {
      const root = tmp();
      mkdirSync(root, { recursive: true });
      writeFileSync(path.join(root, "modelguild.conf.local"), "GUILD_MODEL=openai/local\n");
      t.check(resolveConfFile(root, {})?.endsWith("modelguild.conf.local") === true,
        "resolveConfFile: <root>/modelguild.conf.local when present");
      t.check(resolveConfFile(root, { GUILD_CONF: "/custom/conf" } as NodeJS.ProcessEnv) === "/custom/conf",
        "resolveConfFile: $GUILD_CONF overrides");
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

    // ---- panel precedence: args > $GUILD_MODELS env > conf GUILD_MODELS -------
    {
      const confModels = "GUILD_MODELS=openai/from-conf google/from-conf\n";
      const fromConf = resolvePanelModels({ args: [], env: {} as NodeJS.ProcessEnv, confContents: confModels });
      t.check(fromConf.models.join(",") === "openai/from-conf,google/from-conf",
        "panel: conf GUILD_MODELS used when args/env absent");
      const fromEnv = resolvePanelModels({ args: [], env: { GUILD_MODELS: "openai/env google/env" } as NodeJS.ProcessEnv, confContents: confModels });
      t.check(fromEnv.models.join(",") === "openai/env,google/env", "panel: env overrides conf");
    }

  } finally {
    cleanup();
  }

  console.log(`config.test: ${t.passes} passed, ${t.failures} failed`);
  return t.failures;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  run().then((f) => process.exit(f > 0 ? 1 : 0));
}
