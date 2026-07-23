/**
 * FLAGSHIP ORPHAN TEST (PLAN.md M1 kill signal).
 *
 * Simulates Claude Code's teardown FAITHFULLY: it spawns the MCP server as a child
 * over stdio pipes (the way Claude Code does), drives one `collab_status` call to
 * bring `opencode serve` up and learn its pid, then tears the server down by CLOSING
 * THE CHILD'S STDIN WITH NO SIGNAL — never `kill()`, never SIGTERM/SIGINT. The serve
 * child (captured beforehand) must be dead within a grace window.
 *
 * This is driven twice through the SAME server code, differing by ONE variable:
 *   - production ("stdin" mode): stdin EOF is watched → serve dies fast. MUST be green.
 *   - spike ("spike" mode, COLLAB_TEARDOWN_MODE=spike): stdin is NOT watched, only the
 *     MCP transport.onclose + signal/exit backstop — the spike's approach. Because the
 *     SDK's StdioServerTransport never listens for stdin 'end'/'close', onclose does
 *     not fire on EOF and no signal is sent, so the serve is orphaned. MUST be red.
 *
 * The client is HAND-ROLLED (not the MCP SDK client) precisely so teardown is a bare
 * `child.stdin.end()` — the SDK client's close() escalates to SIGTERM/SIGKILL, which
 * would mask the very failure this test exists to catch.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { Checker, pidAlive, waitFor, sleep, tsxBin, serverEntry, repoRoot } from "./harness.js";

const SPAWN_MS = 40_000;
const DEAD_GRACE_MS = 8_000; // production: serve must die within this
const ORPHAN_PROBE_MS = 3_000; // spike: serve is still alive this long after EOF

interface JsonRpc {
  jsonrpc: "2.0";
  id?: number;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: unknown;
}

/** Minimal newline-delimited JSON-RPC client over a child's stdio pipes. */
class HandRolledMcp {
  readonly child: ChildProcess;
  #buf = "";
  #messages: JsonRpc[] = [];

  constructor(entry: string, extraEnv: Record<string, string>) {
    this.child = spawn(tsxBin, [entry], {
      cwd: repoRoot,
      stdio: ["pipe", "pipe", "inherit"], // stderr inherited for diagnostics
      env: { ...process.env, ...extraEnv },
    });
    this.child.stdout!.setEncoding("utf8");
    this.child.stdout!.on("data", (chunk: string) => {
      this.#buf += chunk;
      let nl: number;
      while ((nl = this.#buf.indexOf("\n")) !== -1) {
        const line = this.#buf.slice(0, nl).replace(/\r$/, "");
        this.#buf = this.#buf.slice(nl + 1);
        if (line.length === 0) continue;
        try {
          this.#messages.push(JSON.parse(line) as JsonRpc);
        } catch {
          /* non-JSON banner line — ignore */
        }
      }
    });
  }

  #send(msg: JsonRpc): void {
    this.child.stdin!.write(JSON.stringify(msg) + "\n");
  }

  async #awaitId(id: number, timeoutMs: number): Promise<JsonRpc> {
    const found = await waitFor(
      () => this.#messages.some((m) => m.id === id),
      timeoutMs,
      50,
    );
    if (!found) throw new Error(`no JSON-RPC response for id ${id} within ${timeoutMs}ms`);
    return this.#messages.find((m) => m.id === id)!;
  }

  async initialize(): Promise<void> {
    this.#send({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "orphan-test", version: "0.0.0" },
      },
    });
    await this.#awaitId(1, 15_000);
    this.#send({ jsonrpc: "2.0", method: "notifications/initialized" });
  }

  /** Call collab_status and return the parsed status payload (incl. serve pid). */
  async callStatus(): Promise<{ pid: number; port: number; agentCount: number; opencodeVersion: unknown }> {
    this.#send({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "collab_status", arguments: {} },
    });
    const resp = await this.#awaitId(2, SPAWN_MS);
    if (resp.error) throw new Error(`collab_status errored: ${JSON.stringify(resp.error)}`);
    const result = resp.result as { content?: Array<{ type?: string; text?: string }> };
    const text = result?.content?.[0]?.text ?? "";
    return JSON.parse(text) as { pid: number; port: number; agentCount: number; opencodeVersion: unknown };
  }

  /** THE teardown: close stdin only. No signal. */
  closeStdin(): void {
    this.child.stdin!.end();
  }

  /** Cleanup after a measurement (may use signals — this is NOT the measured teardown). */
  forceKill(servePid?: number): void {
    try {
      if (this.child.pid) process.kill(this.child.pid, "SIGKILL");
    } catch {
      /* gone */
    }
    if (servePid) {
      try {
        process.kill(-servePid, "SIGKILL");
      } catch {
        try {
          process.kill(servePid, "SIGKILL");
        } catch {
          /* gone */
        }
      }
    }
  }
}

interface Outcome {
  servePid: number;
  serveDeadAtGrace: boolean;
  msToServeDeath: number | null;
}

/** Drive one call, capture the serve pid, close stdin (no signal), watch the serve. */
async function driveThenCloseStdin(mode: "stdin" | "spike"): Promise<Outcome> {
  const env: Record<string, string> = { COLLAB_PROJECT_DIR: repoRoot };
  if (mode === "spike") env.COLLAB_TEARDOWN_MODE = "spike";
  const mcp = new HandRolledMcp(serverEntry, env);
  try {
    await mcp.initialize();
    const status = await mcp.callStatus();
    const servePid = status.pid;
    if (!pidAlive(servePid)) throw new Error(`serve pid ${servePid} not alive before teardown`);

    const t0 = Date.now();
    mcp.closeStdin(); // <-- signal-less teardown

    // Watch the serve pid. Production: dies fast. Spike: orphaned.
    const grace = mode === "stdin" ? DEAD_GRACE_MS : ORPHAN_PROBE_MS;
    const dead = await waitFor(() => !pidAlive(servePid), grace, 100);
    const msToServeDeath = dead ? Date.now() - t0 : null;
    return { servePid, serveDeadAtGrace: dead, msToServeDeath };
  } finally {
    // Cleanup only — reap the child and any orphaned serve so nothing leaks past
    // the test. This uses signals by design; it is not part of the measurement.
    const servePidGuess = (mcp.child as ChildProcess).pid;
    void servePidGuess;
    mcp.forceKill();
  }
}

export async function run(): Promise<number> {
  const c = new Checker();
  console.log("== orphan.test (flagship) ==");

  // GREEN: production stdin-watch mode kills the serve on signal-less stdin close.
  const prod = await driveThenCloseStdin("stdin");
  console.log(
    `  [production] serve pid ${prod.servePid} — dead at grace: ${prod.serveDeadAtGrace}` +
      (prod.msToServeDeath !== null ? ` (after ${prod.msToServeDeath}ms)` : ""),
  );
  c.check(
    prod.serveDeadAtGrace,
    `FLAGSHIP: signal-less stdin close killed opencode serve (pid ${prod.servePid}) within ${DEAD_GRACE_MS}ms`,
  );
  // Make sure the production serve really is gone before we spawn the next one.
  try {
    process.kill(-prod.servePid, "SIGKILL");
  } catch {
    /* already dead — expected */
  }
  await sleep(500);

  // RED against the spike's approach: no stdin watch → serve orphaned on EOF.
  const spike = await driveThenCloseStdin("spike");
  console.log(
    `  [spike-approach] serve pid ${spike.servePid} — dead at grace: ${spike.serveDeadAtGrace}` +
      (spike.msToServeDeath !== null ? ` (after ${spike.msToServeDeath}ms)` : ""),
  );
  c.check(
    !spike.serveDeadAtGrace,
    `DISCRIMINATOR: the spike's approach ORPHANS the serve (pid ${spike.servePid} still alive ${ORPHAN_PROBE_MS}ms after signal-less stdin close)`,
  );
  // Reap the orphan we deliberately created.
  try {
    process.kill(-spike.servePid, "SIGKILL");
  } catch {
    /* may already be gone */
  }
  await waitFor(() => !pidAlive(spike.servePid), 8_000);

  console.log(`orphan.test: ${c.passes} passed, ${c.failures} failed`);
  return c.failures;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  run().then((f) => process.exit(f > 0 ? 1 : 0));
}
