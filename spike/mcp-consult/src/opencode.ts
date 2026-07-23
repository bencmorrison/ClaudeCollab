/**
 * Typed boundary for the real opencode wiring.
 *
 * Live implementation for PLAN.md "Rewrite: TypeScript MCP server" spike exit
 * criteria 2 (byte-exact capture) and 4 (session lifecycle incl. cleanup).
 *
 * `askOpencode` lazily spawns a single `opencode serve` (loopback, free port)
 * FROM the project dir whose `.opencode/agent/` holds the agent defs, reuses it
 * across calls, and guarantees no orphan `opencode serve` survives process exit.
 *
 * The stub (`stubAskOpencode`) is retained so the offline `npm test` stays green;
 * `src/server.ts` selects the implementation via `COLLAB_SPIKE_REAL`.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { createServer } from "node:net";
import { writeFile } from "node:fs/promises";

export interface OpencodeAnswer {
  text: string;
  sessionId: string;
  /**
   * Full ordered message history for the session, exactly as returned by
   * `GET /session/{id}/message` (parsed JSON). Undefined for the stub path.
   * Carried here so the capture layer can persist the raw envelope (criterion 2).
   */
  rawHistory?: unknown;
}

/**
 * Ask opencode (via `opencode serve` + its HTTP API, using the `collab-read`
 * agent def) a question and get back its answer.
 */
export type AskOpencode = (question: string, model?: string) => Promise<OpencodeAnswer>;

// --- HTTP timeouts (ms) -----------------------------------------------------
const READY_TIMEOUT_MS = 30_000; // total time to wait for `opencode serve` to answer /doc
const READY_POLL_MS = 250;
const SHORT_HTTP_MS = 15_000; // session create/list/delete/history
const MESSAGE_HTTP_MS = 180_000; // model turn — generous, a real call can be slow

const DEFAULT_MODEL = "opencode/deepseek-v4-flash-free";
const AGENT = "collab-read";

// --- Singleton serve process ------------------------------------------------
interface ServeHandle {
  proc: ChildProcess;
  baseUrl: string;
  port: number;
}

let serverPromise: Promise<ServeHandle> | undefined;
let handlersInstalled = false;
let activeProc: ChildProcess | undefined; // for the synchronous exit-handler backstop

function projectDir(): string {
  return process.env.COLLAB_PROJECT_DIR || process.cwd();
}

/** Ask the OS for a free loopback TCP port by binding to :0 and reading it back. */
function pickFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const addr = srv.address();
      if (addr && typeof addr === "object") {
        const { port } = addr;
        srv.close(() => resolve(port));
      } else {
        srv.close(() => reject(new Error("could not determine a free port")));
      }
    });
  });
}

/** Kill the serve process group (best-effort, synchronous-safe). */
function killServe(proc: ChildProcess | undefined): void {
  if (!proc || proc.killed || proc.pid === undefined) return;
  try {
    // Spawned detached → its own process group; negative pid kills the group,
    // taking down any children opencode serve itself spawned. No orphans.
    process.kill(-proc.pid, "SIGKILL");
  } catch {
    try {
      proc.kill("SIGKILL");
    } catch {
      /* already gone */
    }
  }
}

function installExitHandlers(): void {
  if (handlersInstalled) return;
  handlersInstalled = true;

  // Synchronous backstop: runs on any normal exit.
  process.on("exit", () => killServe(activeProc));

  // Signals: kill the child, then exit (conventional 128+signo).
  const signals: NodeJS.Signals[] = ["SIGINT", "SIGTERM", "SIGHUP"];
  for (const sig of signals) {
    process.on(sig, () => {
      killServe(activeProc);
      process.exit(sig === "SIGINT" ? 130 : sig === "SIGTERM" ? 143 : 129);
    });
  }
}

/** Public shutdown hook — kills the shared serve process if one is running. */
export function shutdownOpencode(): void {
  killServe(activeProc);
  activeProc = undefined;
  serverPromise = undefined;
}

async function startServe(): Promise<ServeHandle> {
  installExitHandlers();
  const port = await pickFreePort();
  const cwd = projectDir();
  const baseUrl = `http://127.0.0.1:${port}`;

  const proc = spawn(
    "opencode",
    ["serve", "--port", String(port), "--hostname", "127.0.0.1"],
    {
      cwd,
      detached: true, // own process group → killable as a unit
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env },
    },
  );
  activeProc = proc;

  // Surface a crash instead of hanging the readiness poll forever.
  let exited = false;
  proc.on("exit", () => {
    exited = true;
    if (activeProc === proc) activeProc = undefined;
  });

  // Poll GET /doc until the server answers or we time out.
  const deadline = Date.now() + READY_TIMEOUT_MS;
  for (;;) {
    if (exited) {
      throw new Error(`opencode serve exited before becoming ready (cwd=${cwd})`);
    }
    try {
      const res = await fetch(`${baseUrl}/doc`, {
        signal: AbortSignal.timeout(SHORT_HTTP_MS),
      });
      if (res.ok) break;
    } catch {
      /* not up yet */
    }
    if (Date.now() > deadline) {
      killServe(proc);
      throw new Error(`opencode serve did not become ready within ${READY_TIMEOUT_MS}ms`);
    }
    await new Promise((r) => setTimeout(r, READY_POLL_MS));
  }

  // Spike affordance: publish the live endpoint so a test harness can verify
  // session lifecycle against the same server (criterion 4, parts d/e).
  const infoPath = process.env.COLLAB_SPIKE_SERVE_INFO;
  if (infoPath) {
    await writeFile(
      infoPath,
      JSON.stringify({ port, baseUrl, pid: proc.pid }) + "\n",
      "utf8",
    ).catch(() => {});
  }

  return { proc, baseUrl, port };
}

function ensureServer(): Promise<ServeHandle> {
  if (!serverPromise) {
    serverPromise = startServe().catch((err) => {
      serverPromise = undefined; // allow a later retry
      throw err;
    });
  }
  return serverPromise;
}

// --- HTTP helpers -----------------------------------------------------------
async function httpJson(url: string, init: RequestInit, timeoutMs: number): Promise<unknown> {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(timeoutMs) });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`${init.method ?? "GET"} ${url} → ${res.status} ${res.statusText} ${body}`);
  }
  return res.json();
}

/** Split a "provider/model" string; default provider is `opencode`. */
function splitModel(spec: string): { providerID: string; modelID: string } {
  const idx = spec.indexOf("/");
  if (idx === -1) return { providerID: "opencode", modelID: spec };
  return { providerID: spec.slice(0, idx), modelID: spec.slice(idx + 1) };
}

/** Concatenate the text of all `text` parts from a message envelope. */
function extractText(msg: unknown): string {
  const parts = (msg as { parts?: Array<{ type?: string; text?: string }> })?.parts;
  if (!Array.isArray(parts)) return "";
  return parts
    .filter((p) => p?.type === "text" && typeof p.text === "string")
    .map((p) => p.text as string)
    .join("");
}

export const askOpencode: AskOpencode = async (question, model) => {
  const spec = model || process.env.COLLAB_SPIKE_MODEL || DEFAULT_MODEL;
  const { providerID, modelID } = splitModel(spec);
  const { baseUrl } = await ensureServer();

  // 1. Create a session bound to the read-only agent def.
  const session = (await httpJson(
    `${baseUrl}/session`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ title: "collab_consult", agent: AGENT }),
    },
    SHORT_HTTP_MS,
  )) as { id?: string };
  const sessionId = session.id;
  if (typeof sessionId !== "string" || sessionId.length === 0) {
    throw new Error(`session create returned no id: ${JSON.stringify(session)}`);
  }

  try {
    // 2. Send the message (synchronous — blocks until the turn completes).
    const final = await httpJson(
      `${baseUrl}/session/${sessionId}/message`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          agent: AGENT,
          model: { providerID, modelID },
          parts: [{ type: "text", text: question }],
        }),
      },
      MESSAGE_HTTP_MS,
    );
    const text = extractText(final);

    // 3. Fetch the FULL ordered history (includes tool parts) for capture.
    const rawHistory = await httpJson(
      `${baseUrl}/session/${sessionId}/message`,
      { method: "GET" },
      SHORT_HTTP_MS,
    );

    return { text, sessionId, rawHistory };
  } finally {
    // 4. Delete the session — best-effort, never masks a real error above.
    await fetch(`${baseUrl}/session/${sessionId}`, {
      method: "DELETE",
      signal: AbortSignal.timeout(SHORT_HTTP_MS),
    }).catch(() => {});
  }
};

/** Stub implementation used by the offline `npm test`. */
export const stubAskOpencode: AskOpencode = async (question, model) => {
  return {
    text: `[STUB] collab_consult received your question (opencode wiring not implemented yet):\n\n${question}`,
    sessionId: `stub-session-${model ?? "default"}`,
  };
};
