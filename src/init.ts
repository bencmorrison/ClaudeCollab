/**
 * `modelguild init` — the installer for the MCP era (PLAN.md M11).
 *
 * Where the bash `install.sh` copies the whole bash payload (ask.sh/log.sh/… + all four
 * agent defs + witness.md) into a project, `init` places ONLY the MCP-era surface:
 *   (a) the 8 command docs (7 migrated + configure) → `.claude/commands/guild/`;
 *   (b) the 3 hardened agent defs the MCP tools resolve (`guild-read`/`guild-build`/
 *       `guild-research`) → `.opencode/agent/` (opencode serve resolves `--agent` from
 *       the project's `.opencode/`, and research/delegate REFUSE if their def is absent —
 *       so these are load-bearing, not optional);
 *   (c) the policy/config templates → `modelguild/` (where `resolveCollabRoot` reads them).
 * It does NOT install the bash wrappers or witness.md — those are retiring (M12).
 *
 * MCP REGISTRATION is user-driven by default: `init` does NOT touch `.mcp.json`. The user
 * registers the server themselves (`claude mcp add modelguild -s <scope> -- …`), choosing
 * per-project or global scope. The opt-in `--write-mcp` flag restores the old behavior —
 * writing/merging the project-scoped `.mcp.json` entry under the KEY `modelguild` (the
 * exact key the command grants `mcp__claudeguild__<tool>` require).
 *
 * OWNERSHIP is ported from `install.sh`'s SHA-256 model, not reinvented: every file we
 * write records the sha256 of its written bytes in `modelguild/.modelguild-install.json`.
 * A re-install UPGRADES a file only while its current bytes still match the hash we
 * recorded (or already equal the incoming payload); a file the user edited is SKIPPED
 * and left untouched (never clobbered), with a warning. `uninstall` removes only
 * hash-verified files. The record file is deliberately named distinctly from bash's
 * `.install-manifest`/`.install-hashes`, so the two installers never read each other's
 * records. Idempotent.
 */

import { createHash } from "node:crypto";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmdirSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";

// ---------------------------------------------------------------------------
// Payload inventory — explicit, like install.sh's PAYLOAD_FILES (no dir walk: a
// source tree can hold ignored/personal files a walk would sweep in).
// ---------------------------------------------------------------------------
const COMMAND_DOCS = [
  "consult",
  "panel",
  "research",
  "review",
  "delegate",
  "workshop",
  "collaborate",
  "configure",
] as const;
/** The hardened agents the MCP tools resolve. collab-watch is witness-only (retired). */
const AGENT_DEFS = ["guild-read", "guild-build", "guild-research"] as const;
const TEMPLATES = ["models.policy", "modelguild.conf.example"] as const;

export interface PayloadEntry {
  /** Path relative to the package root (source). */
  src: string;
  /** Path relative to the target project (destination). Equal to src here. */
  dest: string;
}

export function payloadFiles(): PayloadEntry[] {
  const out: PayloadEntry[] = [];
  for (const c of COMMAND_DOCS) {
    const rel = `.claude/commands/guild/${c}.md`;
    out.push({ src: rel, dest: rel });
  }
  for (const a of AGENT_DEFS) {
    const rel = `.opencode/agent/${a}.md`;
    out.push({ src: rel, dest: rel });
  }
  for (const t of TEMPLATES) {
    const rel = `modelguild/${t}`;
    out.push({ src: rel, dest: rel });
  }
  return out;
}

/** The command docs, for the shadow warning (a same-named non-ours command is silent). */
const COMMAND_DEST_RELS = new Set(
  COMMAND_DOCS.map((c) => `.claude/commands/guild/${c}.md`),
);

/** Deepest-first, pruned on uninstall only when empty (a user file keeps its dir). */
const PRUNE_DIRS = [
  ".claude/commands/guild",
  ".claude/commands",
  ".claude",
  ".opencode/agent",
  ".opencode",
  "modelguild",
];

const RECORD_REL = "modelguild/.modelguild-install.json";
const MCP_KEY = "modelguild";

// ---------------------------------------------------------------------------
// Destination resolution — project (default) vs global.
//
// A payload entry's project-relative `dest` (e.g. `.claude/commands/guild/consult.md`) is
// the stable RECORD KEY in BOTH modes; only the on-disk base changes. `payloadDest` maps a
// dest-rel to `{ base, rel }` so callers pick `safeJoin(base, rel)` (symlink-safe writes,
// init) or `path.join(base, rel)` (plain existence check, doctor) as they need.
// ---------------------------------------------------------------------------
export interface GlobalDirs {
  /** Resolved home dir (defaults to os.homedir()). */
  homeDir: string;
  /** Resolved XDG config home ($XDG_CONFIG_HOME else <homeDir>/.config). */
  xdgConfigHome: string;
}

/** Resolve the global-mode home + XDG dirs, applying injectable overrides ONCE (never read
 * unmockably in a loop). */
export function resolveGlobalDirs(opts: {
  homeDir?: string;
  xdgConfigHome?: string;
  env?: NodeJS.ProcessEnv;
}): GlobalDirs {
  const env = opts.env ?? process.env;
  const homeDir = opts.homeDir && opts.homeDir.length > 0 ? opts.homeDir : os.homedir();
  const xdgConfigHome =
    opts.xdgConfigHome && opts.xdgConfigHome.length > 0
      ? opts.xdgConfigHome
      : env.XDG_CONFIG_HOME && env.XDG_CONFIG_HOME.length > 0
        ? env.XDG_CONFIG_HOME
        : path.join(homeDir, ".config");
  return { homeDir, xdgConfigHome };
}

/**
 * Map a project-relative payload `dest` to its on-disk `{ base, rel }` for the given mode.
 * Project mode: base is the target project (`dest` unchanged). Global mode: commands/policy
 * land under `<home>/.claude/…`, agent defs under `<xdg>/opencode/agent/`.
 */
export function payloadDest(
  destRel: string,
  opts: { global?: boolean; targetDir: string; global_dirs?: GlobalDirs },
): { base: string; rel: string } {
  if (!opts.global) return { base: opts.targetDir, rel: destRel };
  const g = opts.global_dirs;
  if (!g) throw new Error("payloadDest: global mode requires resolved global dirs");
  if (destRel.startsWith(".claude/commands/guild/")) {
    return { base: g.homeDir, rel: destRel }; // <home>/.claude/commands/guild/<name>.md
  }
  if (destRel.startsWith(".opencode/agent/")) {
    // <xdg>/opencode/agent/guild-<x>.md — SINGULAR `agent`, the dir opencode resolves.
    return { base: g.xdgConfigHome, rel: path.join("opencode", destRel.slice(".opencode/".length)) };
  }
  if (destRel.startsWith("modelguild/")) {
    return {
      base: g.homeDir,
      rel: path.join(".claude", "modelguild", destRel.slice("modelguild/".length)),
    };
  }
  throw new Error(`payloadDest: unmapped payload dest '${destRel}'`);
}

/** The full install/uninstall plan for a run: how to resolve each dest, where the ownership
 * record lives, which dirs to prune, and whether a project `.gitignore` block applies. */
interface InstallPlan {
  destFor(destRel: string): string; // absolute, symlink-safe
  recordPath: string;
  pruneDirs: string[]; // absolute, deepest-first
  gitignoreDir?: string; // project mode only
}

function planFor(opts: InitOptions): InstallPlan {
  if (opts.global) {
    const g = resolveGlobalDirs(opts);
    const destOpts = { global: true as const, targetDir: opts.targetDir, global_dirs: g };
    return {
      destFor: (rel) => {
        const { base, rel: r } = payloadDest(rel, destOpts);
        return safeJoin(base, r);
      },
      recordPath: safeJoin(g.homeDir, path.join(".claude", "modelguild", ".modelguild-install.json")),
      pruneDirs: [
        path.join(g.homeDir, ".claude", "commands", "guild"),
        path.join(g.homeDir, ".claude", "commands"),
        path.join(g.xdgConfigHome, "opencode", "agent"),
        path.join(g.homeDir, ".claude", "modelguild"),
      ],
    };
  }
  return {
    destFor: (rel) => safeJoin(opts.targetDir, rel),
    recordPath: safeJoin(opts.targetDir, RECORD_REL),
    pruneDirs: PRUNE_DIRS.map((d) => path.join(opts.targetDir, d)),
    gitignoreDir: opts.targetDir,
  };
}

const GITIGNORE_BEGIN = "# >>> ModelGuild >>>";
const GITIGNORE_END = "# <<< ModelGuild <<<";
const GITIGNORE_BODY = [
  GITIGNORE_BEGIN,
  "# Per-user config written by /guild:configure — never commit personal prefs.",
  "modelguild/models.policy.local",
  "modelguild/modelguild.conf.local",
  "# The evidence layer: raw prompts/responses of every model call (modelguild/logs).",
  "modelguild/logs/",
  GITIGNORE_END,
  "",
].join("\n");

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------
export interface ServerLaunch {
  command: string;
  args: string[];
  /** Extra env keys to write into the `.mcp.json` server entry (GUILD_PROJECT_DIR is
   * always added by init from the target dir). */
  env?: Record<string, string>;
}

export interface InitOptions {
  /** Absolute path to the target project the payload lands in. Ignored when `global`. */
  targetDir: string;
  /** Absolute path to the package root the payload is read from. */
  packageRoot: string;
  /** How `.mcp.json` should launch the MCP server (command/args/env). */
  serverLaunch: ServerLaunch;
  /** true → uninstall (hash-verified removal) instead of install. */
  uninstall?: boolean;
  /** OPT-IN: write/merge the project `.mcp.json` server entry (the old auto-write). Default
   * false — the user registers the server themselves (`claude mcp add`, their choice of
   * scope), so `mcpAction` is `"skipped"` unless this is set. Ignored (forced skipped) in
   * `global` mode — there is no project `.mcp.json`. */
  writeMcp?: boolean;
  /**
   * GLOBAL payload install: place the payload into the user's global config so `/guild:*`,
   * the hardened agent defs, and the policy are available in EVERY project without a
   * per-project `init`. Destinations change (SOURCE files are identical, only DEST differs):
   *   command docs → `<homeDir>/.claude/commands/guild/<name>.md`
   *   agent defs   → `<xdgConfigHome>/opencode/agent/guild-<x>.md`
   *   policy/conf  → `<homeDir>/.claude/modelguild/<file>`
   *   record       → `<homeDir>/.claude/modelguild/.modelguild-install.json` (SEPARATE from
   *                  the per-project record so the two installs never read each other's).
   * No `.gitignore` block is written (there is no project). Same SHA-256 ownership semantics.
   */
  global?: boolean;
  /** Home dir for global-mode destinations. INJECTABLE for tests; defaults to `os.homedir()`.
   * Resolved once (not read unmockably inside the payload loop). */
  homeDir?: string;
  /** XDG config home for the global opencode agent dir. INJECTABLE for tests; defaults to
   * `$XDG_CONFIG_HOME` else `<homeDir>/.config`. */
  xdgConfigHome?: string;
}

export interface InitResult {
  installed: string[];
  skipped: string[];
  removed: string[];
  /** Command docs a user already had at our path that are NOT ours (shadowing). */
  shadowed: string[];
  warnings: string[];
  mcpAction: "created" | "merged" | "updated" | "removed" | "unchanged" | "skipped";
}

type Records = Record<string, string>; // destRel -> sha256(hex)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function sha256(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}

/** Reject `..`, absolute, and empty components — the valid_rel guard from install.sh. */
function validRel(rel: string): boolean {
  if (!rel || path.isAbsolute(rel)) return false;
  const parts = rel.split("/");
  return parts.every((p) => p.length > 0 && p !== "..");
}

/**
 * Resolve `<base>/<rel>` refusing a symlink at ANY existing component — the
 * safe_dest_rel guard: a planted symlink (payload file or intermediate dir) must not
 * redirect a write outside `base`.
 */
function safeJoin(base: string, rel: string): string {
  if (!validRel(rel)) throw new Error(`refusing unsafe path: ${rel}`);
  let cur = base;
  for (const part of rel.split("/")) {
    cur = path.join(cur, part);
    if (existsSync(cur) && lstatSync(cur).isSymbolicLink()) {
      throw new Error(`refusing destination symlink: ${rel}`);
    }
  }
  return cur;
}

function readRecords(recordPath: string): Records {
  const p = recordPath;
  if (!existsSync(p)) return {};
  try {
    const parsed = JSON.parse(readFileSync(p, "utf8")) as { files?: unknown };
    const files = parsed.files;
    if (files && typeof files === "object") {
      const out: Records = {};
      for (const [k, v] of Object.entries(files as Record<string, unknown>)) {
        if (typeof v === "string" && /^[0-9a-f]{64}$/.test(v)) out[k] = v;
      }
      return out;
    }
  } catch {
    /* unreadable/corrupt → treat as no records (conservative: nothing is "owned") */
  }
  return {};
}

function writeRecords(recordPath: string, records: Records): void {
  mkdirSync(path.dirname(recordPath), { recursive: true });
  const body = JSON.stringify({ version: 1, files: records }, null, 2) + "\n";
  writeFileSync(recordPath, body);
}

function ensureDir(p: string): void {
  mkdirSync(p, { recursive: true });
}

// ---------------------------------------------------------------------------
// .mcp.json merge / removal
// ---------------------------------------------------------------------------
export function mcpServerEntry(opts: InitOptions): Record<string, unknown> {
  const env: Record<string, string> = {
    GUILD_PROJECT_DIR: opts.targetDir,
    ...(opts.serverLaunch.env ?? {}),
  };
  return {
    command: opts.serverLaunch.command,
    args: opts.serverLaunch.args,
    env,
  };
}

function writeMcpJson(opts: InitOptions): InitResult["mcpAction"] {
  const p = safeJoin(opts.targetDir, ".mcp.json");
  const entry = mcpServerEntry(opts);
  let root: Record<string, unknown> = {};
  let existed = false;
  let hadKey = false;
  if (existsSync(p)) {
    existed = true;
    const raw = readFileSync(p, "utf8");
    try {
      const parsed = JSON.parse(raw) as unknown;
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        root = parsed as Record<string, unknown>;
      } else {
        throw new Error(".mcp.json is not a JSON object — refusing to overwrite it");
      }
    } catch (err) {
      throw new Error(
        `.mcp.json exists but is not valid JSON (${(err as Error).message}); ` +
          `fix or remove it, then re-run init.`,
      );
    }
  }
  const servers =
    root.mcpServers && typeof root.mcpServers === "object" && !Array.isArray(root.mcpServers)
      ? (root.mcpServers as Record<string, unknown>)
      : {};
  hadKey = Object.prototype.hasOwnProperty.call(servers, MCP_KEY);
  servers[MCP_KEY] = entry;
  root.mcpServers = servers;
  ensureDir(path.dirname(p));
  writeFileSync(p, JSON.stringify(root, null, 2) + "\n");
  if (!existed) return "created";
  return hadKey ? "updated" : "merged";
}

function removeMcpKey(targetDir: string): InitResult["mcpAction"] {
  const p = safeJoin(targetDir, ".mcp.json");
  if (!existsSync(p)) return "unchanged";
  let root: Record<string, unknown>;
  try {
    const parsed = JSON.parse(readFileSync(p, "utf8")) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return "unchanged";
    root = parsed as Record<string, unknown>;
  } catch {
    return "unchanged";
  }
  const servers = root.mcpServers as Record<string, unknown> | undefined;
  if (!servers || typeof servers !== "object") return "unchanged";
  if (!Object.prototype.hasOwnProperty.call(servers, MCP_KEY)) return "unchanged";
  delete servers[MCP_KEY];
  writeFileSync(p, JSON.stringify(root, null, 2) + "\n");
  return "removed";
}

// ---------------------------------------------------------------------------
// gitignore block (idempotent, fenced) — mirrors install.sh's markers so a project
// that also had a bash install shares one block rather than doubling it.
// ---------------------------------------------------------------------------
function stripGitignoreBlock(text: string): string {
  const lines = text.split("\n");
  const begin = lines.indexOf(GITIGNORE_BEGIN);
  const end = lines.indexOf(GITIGNORE_END);
  // Only strip when BOTH markers are present and ordered (a lone begin must not
  // swallow the rest of the file — the install.sh guard).
  if (begin === -1 || end === -1 || begin >= end) return text;
  const before = lines.slice(0, begin);
  // Drop one separator blank line we inserted before the block.
  if (before.length > 0 && before[before.length - 1] === "") before.pop();
  const after = lines.slice(end + 1);
  return [...before, ...after].join("\n");
}

function addGitignoreBlock(targetDir: string): void {
  const p = safeJoin(targetDir, ".gitignore");
  let text = existsSync(p) ? readFileSync(p, "utf8") : "";
  text = stripGitignoreBlock(text); // idempotent — never double-add
  if (text.length > 0 && !text.endsWith("\n")) text += "\n";
  if (text.length > 0) text += "\n";
  text += GITIGNORE_BODY;
  writeFileSync(p, text);
}

function stripGitignoreOnly(targetDir: string): void {
  const p = path.join(targetDir, ".gitignore");
  if (!existsSync(p)) return;
  const stripped = stripGitignoreBlock(readFileSync(p, "utf8"));
  writeFileSync(p, stripped);
}

// ---------------------------------------------------------------------------
// Install / uninstall
// ---------------------------------------------------------------------------
function pruneEmptyDirs(dirs: string[]): void {
  for (const abs of dirs) {
    if (!existsSync(abs)) continue;
    try {
      if (readdirSync(abs).length === 0) rmdirSync(abs);
    } catch {
      /* not empty or not a dir — leave it */
    }
  }
}

export function init(opts: InitOptions): InitResult {
  const result: InitResult = {
    installed: [],
    skipped: [],
    removed: [],
    shadowed: [],
    warnings: [],
    mcpAction: "unchanged",
  };
  const plan = planFor(opts);
  const records = readRecords(plan.recordPath);

  if (opts.uninstall) {
    for (const { dest } of payloadFiles()) {
      const abs = plan.destFor(dest);
      if (!existsSync(abs)) continue;
      const recorded = records[dest];
      if (!recorded) {
        result.warnings.push(`keeping ${dest} — no ownership record to prove it's ours.`);
        continue;
      }
      const current = sha256(readFileSync(abs));
      if (current === recorded) {
        unlinkSync(abs);
        result.removed.push(dest);
      } else {
        result.warnings.push(`keeping changed file ${dest} — it no longer matches what init wrote.`);
      }
    }
    // No project .mcp.json in global mode; the global payload never wrote one.
    result.mcpAction = opts.global ? "unchanged" : removeMcpKey(opts.targetDir);
    // Remove the record file, then (project only) the gitignore block, then empty dirs.
    if (existsSync(plan.recordPath)) unlinkSync(plan.recordPath);
    if (plan.gitignoreDir) stripGitignoreOnly(plan.gitignoreDir);
    pruneEmptyDirs(plan.pruneDirs);
    return result;
  }

  // Install / upgrade.
  const newRecords: Records = {};
  for (const { src, dest } of payloadFiles()) {
    const srcAbs = path.join(opts.packageRoot, src);
    if (!existsSync(srcAbs)) {
      result.warnings.push(`payload source missing in package: ${src} (skipped).`);
      continue;
    }
    const payloadBytes = readFileSync(srcAbs);
    const payloadHash = sha256(payloadBytes);
    const destAbs = plan.destFor(dest);

    if (existsSync(destAbs)) {
      if (!lstatSync(destAbs).isFile()) {
        result.warnings.push(`skipping ${dest} — a non-file exists there; left untouched.`);
        result.skipped.push(dest);
        if (records[dest]) newRecords[dest] = records[dest];
        continue;
      }
      const current = sha256(readFileSync(destAbs));
      const owned = records[dest] === current || current === payloadHash;
      if (!owned) {
        // A file the user already had (or edited). Never clobber it.
        result.skipped.push(dest);
        result.warnings.push(
          `skipping ${dest} — a file you already have is there; left untouched.`,
        );
        if (COMMAND_DEST_RELS.has(dest)) result.shadowed.push(dest);
        if (records[dest]) newRecords[dest] = records[dest];
        continue;
      }
      if (current === payloadHash) {
        // Already up to date — record and move on (idempotent no-write).
        newRecords[dest] = payloadHash;
        continue;
      }
    }
    ensureDir(path.dirname(destAbs));
    writeFileSync(destAbs, payloadBytes);
    newRecords[dest] = payloadHash;
    result.installed.push(dest);
  }

  writeRecords(plan.recordPath, newRecords);
  // MCP registration is user-driven by default (`claude mcp add`, their choice of scope);
  // only the opt-in `--write-mcp` path writes the project `.mcp.json` for them. Global mode
  // has no project `.mcp.json`, so writeMcp is ignored there (forced skipped).
  result.mcpAction = !opts.global && opts.writeMcp ? writeMcpJson(opts) : "skipped";
  // A project `.gitignore` block only makes sense for a project install.
  if (plan.gitignoreDir) addGitignoreBlock(plan.gitignoreDir);
  return result;
}
