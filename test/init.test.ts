/**
 * `modelguild init` test, in the spirit of collab/tests/test-install.sh:
 * install into throwaway temp dirs and assert the file / .mcp.json / ownership behaviour,
 * idempotency, the merge-not-clobber guarantee, hash-verified uninstall, and that the
 * bash wrappers are NOT installed. Offline, no model call. packageRoot is the repo root
 * (the payload assets live there — the same files npm's `files` allowlist ships).
 */

import { existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { Checker, repoRoot } from "./harness.js";
import { init, type ServerLaunch } from "../src/init.js";

// The shipped default launch line: portable, non-interactive npx form.
const LAUNCH: ServerLaunch = { command: "npx", args: ["-y", "modelguild", "serve"] };

function tempProject(): string {
  // realpath: macOS /tmp is a symlink; safeJoin refuses symlink components, so canonicalize.
  return realpathSync(mkdtempSync(path.join(os.tmpdir(), "cc-init-")));
}

function readJson(p: string): any {
  return JSON.parse(readFileSync(p, "utf8"));
}

export async function run(): Promise<number> {
  const c = new Checker();
  console.log("== init.test ==");

  // --- fresh install (DEFAULT: does NOT write .mcp.json) -------------------
  const T = tempProject();
  const res = init({ targetDir: T, packageRoot: repoRoot, serverLaunch: LAUNCH });

  c.check(res.installed.length === 13, `installs 13 files (8 docs + 3 agents + 2 templates) (got ${res.installed.length})`);
  c.check(existsSync(path.join(T, ".claude/commands/guild/consult.md")), "places a command doc");
  c.check(existsSync(path.join(T, ".claude/commands/guild/configure.md")), "places configure.md (the 8th doc)");
  c.check(existsSync(path.join(T, ".opencode/agent/guild-read.md")), "places guild-read agent def");
  c.check(existsSync(path.join(T, ".opencode/agent/guild-research.md")), "places guild-research agent def");
  c.check(existsSync(path.join(T, ".opencode/agent/guild-build.md")), "places guild-build agent def");
  c.check(existsSync(path.join(T, "modelguild/models.policy")), "places models.policy template");
  c.check(existsSync(path.join(T, "modelguild/modelguild.conf.example")), "places modelguild.conf.example template");
  c.check(existsSync(path.join(T, "modelguild/.modelguild-install.json")), "writes the ownership record file");

  // The MCP-era payload must NOT ship the bash wrappers or witness.md.
  c.check(!existsSync(path.join(T, "modelguild/ask.sh")), "does NOT install modelguild/ask.sh");
  c.check(!existsSync(path.join(T, "modelguild/log.sh")), "does NOT install modelguild/log.sh");
  c.check(!existsSync(path.join(T, "modelguild/panel-models.sh")), "does NOT install panel-models.sh");
  c.check(!existsSync(path.join(T, ".claude/commands/guild/witness.md")), "does NOT install witness.md");
  c.check(!existsSync(path.join(T, ".opencode/agent/guild-watch.md")), "does NOT install guild-watch (witness) agent");

  // --- DEFAULT: .mcp.json is NOT written; user registers the server -------
  c.check(res.mcpAction === "skipped", "default install reports .mcp.json 'skipped' (user registers it)");
  c.check(!existsSync(path.join(T, ".mcp.json")), "default install does NOT create .mcp.json");

  // --- opt-in --write-mcp: the old auto-write of the project .mcp.json ----
  const Tw = tempProject();
  const resw = init({ targetDir: Tw, packageRoot: repoRoot, serverLaunch: LAUNCH, writeMcp: true });
  c.check(resw.mcpAction === "created", "--write-mcp reports .mcp.json created");
  const mcp = readJson(path.join(Tw, ".mcp.json"));
  c.check(
    !!mcp.mcpServers && Object.prototype.hasOwnProperty.call(mcp.mcpServers, "modelguild"),
    "--write-mcp .mcp.json has the 'modelguild' key (matches mcp__modelguild__* grants)",
  );
  const entry = mcp.mcpServers.modelguild;
  c.check(
    entry.command === "npx" &&
      JSON.stringify(entry.args) === JSON.stringify(["-y", "modelguild", "serve"]),
    "launch line is the portable non-interactive default `npx -y modelguild serve`",
  );
  c.check(entry.env?.GUILD_PROJECT_DIR === Tw, "--write-mcp .mcp.json entry sets GUILD_PROJECT_DIR to the target dir");

  // --- gitignore -----------------------------------------------------------
  const gi = readFileSync(path.join(T, ".gitignore"), "utf8");
  c.check(gi.includes("ModelGuild >>>") && gi.includes("modelguild/logs/"), "gitignore block written");

  // --- idempotent re-run ---------------------------------------------------
  const res2 = init({ targetDir: T, packageRoot: repoRoot, serverLaunch: LAUNCH });
  c.check(res2.installed.length === 0 && res2.skipped.length === 0, "re-run writes 0 files (idempotent)");
  const giCount = (readFileSync(path.join(T, ".gitignore"), "utf8").match(/ModelGuild >>>/g) || []).length;
  c.check(giCount === 1, "re-run keeps exactly one gitignore block");

  // --- upgrade: a stale-but-owned file is overwritten ----------------------
  const consultPath = path.join(T, ".claude/commands/guild/consult.md");
  const original = readFileSync(consultPath);
  // Simulate a prior-version file: overwrite its bytes AND record the new hash as ours,
  // so the ownership check treats it as owned (it matches the recorded hash).
  writeFileSync(consultPath, "OLD OWNED CONTENT\n");
  const recPath = path.join(T, "modelguild/.modelguild-install.json");
  const rec = readJson(recPath);
  const { createHash } = await import("node:crypto");
  rec.files[".claude/commands/guild/consult.md"] = createHash("sha256").update("OLD OWNED CONTENT\n").digest("hex");
  writeFileSync(recPath, JSON.stringify(rec, null, 2) + "\n");
  const res3 = init({ targetDir: T, packageRoot: repoRoot, serverLaunch: LAUNCH });
  c.check(res3.installed.includes(".claude/commands/guild/consult.md"), "an owned-but-stale file is upgraded");
  c.check(readFileSync(consultPath).equals(original), "upgrade restores the current payload bytes");

  // --- merge-not-clobber: a user-edited file is left untouched + shadow-warned
  writeFileSync(consultPath, "MY OWN COMMAND — DO NOT TOUCH\n");
  const res4 = init({ targetDir: T, packageRoot: repoRoot, serverLaunch: LAUNCH });
  c.check(
    readFileSync(consultPath, "utf8") === "MY OWN COMMAND — DO NOT TOUCH\n",
    "a user-edited command doc is NOT clobbered",
  );
  c.check(res4.skipped.includes(".claude/commands/guild/consult.md"), "the edited file is reported skipped");
  c.check(res4.shadowed.includes(".claude/commands/guild/consult.md"), "an unowned command doc raises a shadow warning");

  // --- --write-mcp merge preserves a sibling server ------------------------
  const T2 = tempProject();
  writeFileSync(
    path.join(T2, ".mcp.json"),
    JSON.stringify({ mcpServers: { other: { command: "x", args: [] } }, someOtherKey: 1 }, null, 2),
  );
  const resm = init({ targetDir: T2, packageRoot: repoRoot, serverLaunch: LAUNCH, writeMcp: true });
  c.check(resm.mcpAction === "merged", "existing .mcp.json without our key → merged (--write-mcp)");
  const mcp2 = readJson(path.join(T2, ".mcp.json"));
  c.check(!!mcp2.mcpServers.other && !!mcp2.mcpServers.modelguild, "merge keeps the sibling server AND adds ours");
  c.check(mcp2.someOtherKey === 1, "merge preserves unrelated top-level keys");

  // --- invalid .mcp.json is refused, not clobbered (--write-mcp path) ------
  const T3 = tempProject();
  writeFileSync(path.join(T3, ".mcp.json"), "{ not json");
  let refused = false;
  try {
    init({ targetDir: T3, packageRoot: repoRoot, serverLaunch: LAUNCH, writeMcp: true });
  } catch {
    refused = true;
  }
  c.check(refused, "invalid .mcp.json is refused rather than overwritten");
  c.check(readFileSync(path.join(T3, ".mcp.json"), "utf8") === "{ not json", "the invalid .mcp.json is left untouched");

  // --- uninstall: hash-verified removal (install with --write-mcp so there is
  //     a .mcp.json key for uninstall to clean up) --------------------------
  const T4 = tempProject();
  init({ targetDir: T4, packageRoot: repoRoot, serverLaunch: LAUNCH, writeMcp: true });
  // A user file the installer never wrote must survive.
  writeFileSync(path.join(T4, ".claude/commands/guild/mine.md"), "keep me\n");
  // A user EDIT to one of our files must survive uninstall (hash no longer matches).
  writeFileSync(path.join(T4, ".claude/commands/guild/panel.md"), "edited by user\n");
  const resu = init({ targetDir: T4, packageRoot: repoRoot, serverLaunch: LAUNCH, uninstall: true });
  c.check(resu.removed.includes(".claude/commands/guild/consult.md"), "uninstall removes a pristine owned file");
  c.check(!existsSync(path.join(T4, ".opencode/agent/guild-read.md")), "uninstall removes agent defs");
  c.check(existsSync(path.join(T4, ".claude/commands/guild/mine.md")), "uninstall keeps a user's own file");
  c.check(
    existsSync(path.join(T4, ".claude/commands/guild/panel.md")),
    "uninstall keeps a file the user edited (hash mismatch → not ours to delete)",
  );
  c.check(resu.mcpAction === "removed", "uninstall removes the modelguild .mcp.json key");
  const mcpu = readJson(path.join(T4, ".mcp.json"));
  c.check(
    !mcpu.mcpServers || !Object.prototype.hasOwnProperty.call(mcpu.mcpServers, "modelguild"),
    "the modelguild key is gone after uninstall",
  );
  c.check(!existsSync(path.join(T4, "modelguild/.modelguild-install.json")), "uninstall removes the ownership record");
  const giu = existsSync(path.join(T4, ".gitignore")) ? readFileSync(path.join(T4, ".gitignore"), "utf8") : "";
  c.check(!giu.includes("ModelGuild >>>"), "uninstall strips the gitignore block");

  // --- GLOBAL payload install (init --global) ------------------------------
  // Inject fake home + XDG dirs so nothing touches the real ~/.claude / ~/.config.
  const G_HOME = tempProject();
  const G_XDG = tempProject();
  const gOpts = { homeDir: G_HOME, xdgConfigHome: G_XDG };
  const cmdDir = path.join(G_HOME, ".claude/commands/guild");
  const agentDir = path.join(G_XDG, "opencode/agent");
  const mgDir = path.join(G_HOME, ".claude/modelguild");

  const resg = init({ targetDir: tempProject(), packageRoot: repoRoot, serverLaunch: LAUNCH, global: true, ...gOpts });
  c.check(resg.installed.length === 13, `global install writes 13 files (got ${resg.installed.length})`);
  c.check(existsSync(path.join(cmdDir, "consult.md")), "global: command doc lands in <home>/.claude/commands/guild/");
  c.check(existsSync(path.join(cmdDir, "configure.md")), "global: configure.md lands in the global commands dir");
  c.check(existsSync(path.join(agentDir, "guild-read.md")), "global: agent def lands in <xdg>/opencode/agent/");
  c.check(existsSync(path.join(agentDir, "guild-build.md")), "global: guild-build lands in the global agent dir");
  c.check(existsSync(path.join(agentDir, "guild-research.md")), "global: guild-research lands in the global agent dir");
  c.check(existsSync(path.join(mgDir, "models.policy")), "global: policy lands in <home>/.claude/modelguild/");
  c.check(existsSync(path.join(mgDir, ".modelguild-install.json")), "global: ownership record lands in <home>/.claude/modelguild/");
  c.check(resg.mcpAction === "skipped", "global install never writes .mcp.json (skipped)");
  // The project dir must be untouched by a global install.
  c.check(!existsSync(path.join(G_HOME, ".opencode")), "global: does NOT create a project .opencode under home");

  // Global record is SEPARATE from any project record (distinct file, distinct location).
  const gRec = readJson(path.join(mgDir, ".modelguild-install.json"));
  c.check(
    Object.prototype.hasOwnProperty.call(gRec.files, ".claude/commands/guild/consult.md"),
    "global record keys by the stable project-relative dest",
  );

  // Idempotent re-run.
  const resg2 = init({ targetDir: tempProject(), packageRoot: repoRoot, serverLaunch: LAUNCH, global: true, ...gOpts });
  c.check(resg2.installed.length === 0 && resg2.skipped.length === 0, "global re-run writes 0 files (idempotent)");

  // A user-edited global file is NOT clobbered.
  const gConsult = path.join(cmdDir, "consult.md");
  writeFileSync(gConsult, "MY GLOBAL EDIT\n");
  const resg3 = init({ targetDir: tempProject(), packageRoot: repoRoot, serverLaunch: LAUNCH, global: true, ...gOpts });
  c.check(readFileSync(gConsult, "utf8") === "MY GLOBAL EDIT\n", "global: a user-edited file is not clobbered");
  c.check(resg3.skipped.includes(".claude/commands/guild/consult.md"), "global: the edited file is reported skipped");

  // uninstall --global removes only hash-verified files; the user-edited one survives.
  const resgu = init({ targetDir: tempProject(), packageRoot: repoRoot, serverLaunch: LAUNCH, global: true, uninstall: true, ...gOpts });
  c.check(resgu.removed.includes(".opencode/agent/guild-read.md"), "uninstall --global removes a pristine owned agent def");
  c.check(!existsSync(path.join(agentDir, "guild-read.md")), "uninstall --global deletes the agent def from the global dir");
  c.check(existsSync(gConsult), "uninstall --global keeps the user-edited file (hash mismatch)");
  c.check(!existsSync(path.join(mgDir, ".modelguild-install.json")), "uninstall --global removes the global ownership record");
  c.check(resgu.mcpAction === "unchanged", "uninstall --global does not touch any .mcp.json");

  console.log(`init.test: ${c.passes} passed, ${c.failures} failed`);
  return c.failures;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  run().then((f) => process.exit(f > 0 ? 1 : 0));
}
