/**
 * `modelguild` CLI dispatcher (PLAN.md M11).
 *
 * The published npm package's `bin`. Subcommands:
 *   serve   (default) — start the MCP stdio server (what `.mcp.json` launches).
 *   init              — place the MCP-era payload into a project (see init.ts).
 *   doctor            — a token-free health check (opencode present, MCP registration,
 *                       command docs + agent defs present, config/policy roots).
 *
 * NOTE: this file carries NO shebang in source, on purpose — the repo's shebang lint
 * (`check-shebangs.sh`) requires `#!/usr/bin/env bash` on every tracked script, and this
 * is a node entry. The build step (`scripts/postbuild.mjs`) prepends `#!/usr/bin/env node`
 * to the git-ignored `dist/cli.js`, which is what npm links as the bin — so the tracked
 * source stays lint-clean while the shipped artifact is directly executable.
 */

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { init, mcpServerEntry, type ServerLaunch } from "./init.js";
import { payloadFiles } from "./init.js";

const SELF = fileURLToPath(import.meta.url); // <pkg>/dist/cli.js  or  <pkg>/src/cli.ts
const PACKAGE_ROOT = path.resolve(path.dirname(SELF), "..");

/** How the running CLI would re-launch itself for the `serve` entry. Honest by
 * construction: it names the exact interpreter+entry that is executing right now, so the
 * `.mcp.json` line init writes is provably runnable (it just ran init). `.ts` ⇒ tsx
 * (dogfood/dev); `.js` ⇒ node (the built/installed artifact). */
/** The SHIPPED DEFAULT: the portable, non-interactive published form
 * `npx -y modelguild serve`. `-y` is load-bearing — an MCP server is launched on a
 * non-TTY, where a bare `npx modelguild` would BLOCK on npm's "install this package?"
 * prompt with no way to answer. Requires the package to be resolvable (published, or a
 * project dependency). Also chosen explicitly with `--npx`. */
function npxServeLaunch(): ServerLaunch {
  return { command: "npx", args: ["-y", "modelguild", "serve"] };
}

/** The pinned/offline form (`--abs`): an absolute path to the exact interpreter+entry
 * running right now, so it needs no registry resolution — guaranteed runnable but
 * machine-specific. `.ts` ⇒ tsx (dogfood/dev); `.js` ⇒ node (the built artifact). */
function absServeLaunch(): ServerLaunch {
  if (SELF.endsWith(".ts")) return { command: "npx", args: ["tsx", SELF, "serve"] };
  return { command: "node", args: [SELF, "serve"] };
}

async function runServe(): Promise<void> {
  // server.ts self-runs on import: it constructs the Server, wires stdin/transport
  // teardown, and connects the stdio transport at module top level.
  await import("./server.js");
}

function parseInitArgs(argv: string[]): {
  targetDir: string;
  uninstall: boolean;
  launch: ServerLaunch;
  writeMcp: boolean;
} {
  let targetDir = process.cwd();
  let uninstall = false;
  let useAbs = false;
  let writeMcp = false;
  let customCommand: string | undefined;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--uninstall") uninstall = true;
    // --npx is the default already; accepted as an explicit no-op for clarity.
    else if (a === "--npx") useAbs = false;
    else if (a === "--abs") useAbs = true;
    // OPT-IN: restore the old auto-write of the project `.mcp.json` entry.
    else if (a === "--write-mcp") writeMcp = true;
    else if (a === "--dir") targetDir = argv[++i] ?? targetDir;
    else if (a.startsWith("--dir=")) targetDir = a.slice("--dir=".length);
    else if (a === "--server-command") customCommand = argv[++i];
    else if (a.startsWith("--server-command=")) customCommand = a.slice("--server-command=".length);
    else throw new Error(`init: unknown argument '${a}'`);
  }
  targetDir = path.resolve(targetDir);
  let launch: ServerLaunch;
  if (customCommand !== undefined) {
    const parts = customCommand.split(/\s+/).filter((p) => p.length > 0);
    if (parts.length === 0) throw new Error("init: --server-command is empty");
    launch = { command: parts[0], args: parts.slice(1) };
  } else if (useAbs) {
    launch = absServeLaunch();
  } else {
    launch = npxServeLaunch(); // SHIPPED DEFAULT
  }
  return { targetDir, uninstall, launch, writeMcp };
}

function runInit(argv: string[]): number {
  const { targetDir, uninstall, launch, writeMcp } = parseInitArgs(argv);
  const res = init({ targetDir, packageRoot: PACKAGE_ROOT, serverLaunch: launch, uninstall, writeMcp });

  if (uninstall) {
    console.log(`Uninstalled ModelGuild (MCP) from ${targetDir}`);
    console.log(`  removed ${res.removed.length} file(s); .mcp.json ${res.mcpAction}`);
  } else {
    console.log(`Installed ModelGuild (MCP) into ${targetDir}`);
    console.log(`  ${res.installed.length} file(s) written, ${res.skipped.length} skipped`);
    if (writeMcp) {
      console.log(`  .mcp.json: ${res.mcpAction} — server key 'modelguild'`);
    } else {
      console.log(`  .mcp.json: NOT written — register the server yourself (see below).`);
    }
    console.log(`  launch: ${launch.command} ${launch.args.join(" ")}`);
  }
  for (const w of res.warnings) console.warn(`  ! ${w}`);
  if (res.shadowed.length > 0) {
    console.warn(
      `  ! ${res.shadowed.length} command(s) already existed at our path and are NOT ours ` +
        `(shadowing): ${res.shadowed.join(", ")}. Those /guild:* commands are the user's, ` +
        `not ModelGuild's — rename or remove them and re-run to use ours.`,
    );
  }
  if (!uninstall && !writeMcp) printRegisterInstructions(targetDir, launch);
  if (!uninstall) {
    console.log("Next steps:");
    console.log("  1. Authenticate opencode:  opencode auth login");
    if (!writeMcp) {
      console.log("  2. Register the MCP server (see 'Register the MCP server' above).");
    } else {
      console.log("  2. (Done — --write-mcp wrote the project .mcp.json for you.)");
    }
    console.log("  3. Restart Claude Code so it picks up the MCP server.");
    console.log("  4. Check the setup:        npx modelguild doctor");
  }
  return 0;
}

/** Print the two ways to register the MCP server, in the DEFAULT (no `--write-mcp`) path:
 * the recommended `claude mcp add` CLI form (any scope), and the raw `.mcp.json` snippet for
 * hand-placement. The snippet reuses `mcpServerEntry` so its shape can't drift from what
 * `--write-mcp` would write. */
function printRegisterInstructions(targetDir: string, launch: ServerLaunch): void {
  const launchStr = [launch.command, ...launch.args].join(" ");
  console.log("");
  console.log("Register the MCP server (init did NOT write .mcp.json — you choose the scope):");
  console.log("");
  console.log("  Recommended — register with the Claude CLI:");
  console.log(`    claude mcp add modelguild -s user -- ${launchStr}`);
  console.log(
    "    Swap -s user (global, all your projects) for -s project (committed to this " +
      "repo's .mcp.json) or -s local (this project only, private).",
  );
  console.log("");
  console.log("  Or hand-place this in the project's .mcp.json (project-scoped):");
  const snippet = { mcpServers: { modelguild: mcpServerEntry({ targetDir, packageRoot: PACKAGE_ROOT, serverLaunch: launch }) } };
  for (const l of JSON.stringify(snippet, null, 2).split("\n")) console.log(`    ${l}`);
  console.log("");
}

/** A light, token-free doctor: no model call. Confirms the MCP-era payload is present
 * and coherent. This is the deep check — the bash `collab/doctor.sh` was retired at M12. */
async function runDoctor(argv: string[]): Promise<number> {
  let targetDir = process.cwd();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dir") targetDir = argv[++i] ?? targetDir;
    else if (a.startsWith("--dir=")) targetDir = a.slice("--dir=".length);
  }
  targetDir = path.resolve(targetDir);
  let ok = true;
  const line = (good: boolean, msg: string) => {
    console.log(`${good ? "✓" : "✗"} ${msg}`);
    if (!good) ok = false;
  };

  const { spawnSync } = await import("node:child_process");

  // MCP registration under the exact key the command grants require. Since the flip to
  // user-driven registration (init no longer writes .mcp.json by default), the user often
  // registers GLOBALLY (`claude mcp add -s user`, which writes ~/.claude.json, NOT the
  // project .mcp.json) — so a project-file check alone would falsely fail a working global
  // setup. Prefer an any-scope check via the Claude CLI; fall back to the project file.
  const mcpPath = path.join(targetDir, ".mcp.json");
  let projectHasKey = false;
  if (existsSync(mcpPath)) {
    try {
      const root = JSON.parse(readFileSync(mcpPath, "utf8")) as {
        mcpServers?: Record<string, unknown>;
      };
      projectHasKey = !!root.mcpServers && Object.prototype.hasOwnProperty.call(root.mcpServers, "modelguild");
    } catch {
      /* invalid json → treated as no key */
    }
  }
  const claudeGet = spawnSync("claude", ["mcp", "get", "modelguild"], { encoding: "utf8" });
  const claudeOnPath = !claudeGet.error; // ENOENT sets .error
  if (claudeOnPath && claudeGet.status === 0) {
    console.log("✓ MCP server 'modelguild' registered (found via `claude mcp get`, any scope)");
  } else if (projectHasKey) {
    console.log("✓ MCP server registered in project .mcp.json under key 'modelguild'");
  } else if (claudeOnPath) {
    // claude answered, no registration in any scope — a real miss.
    line(false, "MCP server 'modelguild' not registered in any scope — run `claude mcp add modelguild -s user -- npx -y modelguild serve`");
  } else {
    // Can't check global scope (claude not on PATH) and no project key. Do NOT hard-fail: a
    // global/user-scope registration lives in ~/.claude.json, invisible here.
    console.warn(
      "! MCP server 'modelguild' not found in project .mcp.json, and the `claude` CLI isn't " +
        "on PATH to check global/user scope. If you registered with `-s user`, that's expected — " +
        "verify with `claude mcp get modelguild`.",
    );
  }

  // Command docs + agent defs present.
  let docsPresent = 0;
  let agentsPresent = 0;
  for (const { dest } of payloadFiles()) {
    if (!existsSync(path.join(targetDir, dest))) continue;
    if (dest.startsWith(".claude/commands/")) docsPresent++;
    else if (dest.startsWith(".opencode/agent/")) agentsPresent++;
  }
  line(docsPresent >= 7, `${docsPresent}/8 command docs present in .claude/commands/guild/`);
  line(agentsPresent === 3, `${agentsPresent}/3 hardened agent defs present in .opencode/agent/`);

  // Policy / config templates present.
  line(
    existsSync(path.join(targetDir, "modelguild/models.policy")),
    "model policy present (modelguild/models.policy)",
  );

  // opencode binary (best-effort; a missing binary is a warning, not a hard fail here).
  const oc = spawnSync("opencode", ["--version"], { encoding: "utf8" });
  if (oc.status === 0) {
    console.log(`✓ opencode present (${(oc.stdout || "").trim()})`);
  } else {
    console.warn("! opencode not found on PATH — run its install and `opencode auth login`");
  }

  console.log(ok ? "\ndoctor: OK" : "\ndoctor: problems found (see ✗ above)");
  return ok ? 0 : 1;
}

async function main(): Promise<number> {
  const argv = process.argv.slice(2);
  const cmd = argv[0];
  // Default (no subcommand) and `serve` both start the MCP server.
  if (cmd === undefined || cmd === "serve") {
    await runServe();
    return 0; // serve blocks on the transport; this returns only on teardown.
  }
  if (cmd === "init") return runInit(argv.slice(1));
  if (cmd === "doctor") return runDoctor(argv.slice(1));
  if (cmd === "-h" || cmd === "--help" || cmd === "help") {
    console.log("Usage: modelguild <serve|init|doctor> [options]");
    console.log("  serve            Start the MCP stdio server (default; what .mcp.json launches).");
    console.log("  init [--dir D]   Place the MCP-era payload into a project (--uninstall to remove).");
    console.log("                   Does NOT write .mcp.json by default — it prints how to register");
    console.log("                   the server yourself (`claude mcp add`, your choice of scope).");
    console.log("       [--write-mcp]  Opt in to the old behavior: write/merge the project .mcp.json.");
    console.log("       [--npx]     Default launch line: `npx -y modelguild serve`.");
    console.log("       [--abs]     Pin an absolute path to this interpreter+entry (offline/no-registry).");
    console.log("       [--server-command \"cmd args\"]  Override the launch command verbatim.");
    console.log("  doctor [--dir D] Token-free health check.");
    return 0;
  }
  console.error(`modelguild: unknown command '${cmd}' (see --help)`);
  return 2;
}

main().then(
  (code) => {
    // `serve` never resolves until teardown; init/doctor set the exit code.
    if (code !== 0) process.exitCode = code;
  },
  (err) => {
    console.error(`modelguild: ${(err as Error).message}`);
    process.exitCode = 1;
  },
);
