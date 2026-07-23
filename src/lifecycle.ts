/**
 * `opencode serve` lifecycle supervisor (PLAN.md milestone M1).
 *
 * Manages a single `opencode serve` child on loopback: lazy spawn, free-port
 * negotiation, readiness poll, crash-revive, idle timeout, and — the load-bearing
 * part — SHUTDOWN KEYED ON STDIN EOF AND TRANSPORT CLOSE, NOT SIGNALS.
 *
 * Why not signals: the spike proved Claude Code's MCP teardown does NOT deliver a
 * catchable signal to the server process (reproduced under both `claude -p` and the
 * maintainer's interactive session — see spike/mcp-consult/REPORT.md and PLAN.md G0).
 * What it DOES do is close the server's stdin. And the MCP SDK's StdioServerTransport
 * only ever registers a `data` listener on stdin — never `end`/`close` — so stdin EOF
 * does not fire the transport's `onclose` either. The only reliable trigger is to watch
 * `process.stdin` end/close ourselves. Signal and process-`exit` handlers are kept as a
 * strictly second layer, never the primary mechanism.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { createServer } from "node:net";
import type { Readable } from "node:stream";

export interface LifecycleOptions {
  /** Project dir to spawn `opencode serve` from (its `.opencode/agent/` holds the defs). */
  projectDir?: string;
  /** Loopback host to bind. Kept configurable for tests; production stays 127.0.0.1. */
  host?: string;
  /** Idle timeout (ms) after which an idle serve is killed. 0 disables. */
  idleMs?: number;
  /** Per-call mode: spawn a fresh serve per call and kill it when the call returns. */
  perCall?: boolean;
  /** Total time to wait for `opencode serve` to answer GET /doc. */
  readyTimeoutMs?: number;
}

/** The live serve endpoint exposed to callers (no child handle leaked out). */
export interface ServeHandle {
  baseUrl: string;
  port: number;
  pid: number;
}

interface InternalHandle extends ServeHandle {
  proc: ChildProcess;
  exited: boolean;
}

const DEFAULT_IDLE_MS = 600_000; // 10 minutes
const READY_TIMEOUT_MS = 30_000;
const READY_POLL_MS = 250;
const READY_HTTP_MS = 5_000;

function envInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

/**
 * Ask the OS for a free loopback TCP port by binding to :0 and reading it back.
 *
 * Accepted TOCTOU: this probe listener closes before `opencode serve` binds the
 * same port, leaving a gap another process could win. There's no way to close it —
 * opencode has no `--port 0` readback that would let us hand it an already-bound
 * socket. A racer landing in that gap surfaces loudly, as `opencode serve` exiting
 * before becoming ready (see the readiness poll in `#start`), never as a silent hang.
 */
function pickFreePort(host: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.on("error", reject);
    srv.listen(0, host, () => {
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

/** Kill a serve process group (best-effort, synchronous-safe). */
function killServe(proc: ChildProcess | undefined): void {
  if (!proc || proc.killed || proc.pid === undefined) return;
  try {
    // Spawned detached → its own process group; the negative pid takes down any
    // children `opencode serve` spawned as a unit, so nothing is orphaned.
    process.kill(-proc.pid, "SIGKILL");
  } catch {
    try {
      proc.kill("SIGKILL");
    } catch {
      /* already gone */
    }
  }
}

export class OpencodeLifecycle {
  readonly #projectDir: string;
  readonly #host: string;
  readonly #idleMs: number;
  readonly #perCall: boolean;
  readonly #readyTimeoutMs: number;

  #handle: InternalHandle | undefined;
  #startPromise: Promise<InternalHandle> | undefined;
  #inFlight = 0;
  #idleTimer: NodeJS.Timeout | undefined;
  #backstopInstalled = false;
  #triggersAttached = false;

  constructor(opts: LifecycleOptions = {}) {
    this.#projectDir = opts.projectDir ?? process.env.COLLAB_PROJECT_DIR ?? process.cwd();
    this.#host = opts.host ?? "127.0.0.1";
    this.#idleMs = opts.idleMs ?? envInt("COLLAB_SERVE_IDLE_MS", DEFAULT_IDLE_MS);
    this.#perCall = opts.perCall ?? process.env.COLLAB_SERVE_PER_CALL === "1";
    this.#readyTimeoutMs = opts.readyTimeoutMs ?? READY_TIMEOUT_MS;
  }

  // --- Observable state (for tests and diagnostics) -------------------------
  get isRunning(): boolean {
    return this.#handle !== undefined && !this.#handle.exited;
  }
  get pid(): number | undefined {
    return this.isRunning ? this.#handle!.pid : undefined;
  }
  get port(): number | undefined {
    return this.isRunning ? this.#handle!.port : undefined;
  }
  get perCall(): boolean {
    return this.#perCall;
  }
  get idleMs(): number {
    return this.#idleMs;
  }

  /** Lazily spawn (or crash-revive) the serve child and return its live endpoint. */
  async ensureServe(): Promise<ServeHandle> {
    // Crash-revive: a handle whose child has exited (idle death, or an external
    // kill) is stale — drop it so the next line respawns.
    if (this.#handle && this.#handle.exited) {
      this.#handle = undefined;
    }
    if (this.#handle) return this.#public(this.#handle);
    if (!this.#startPromise) {
      this.#startPromise = this.#start().finally(() => {
        this.#startPromise = undefined;
      });
    }
    const h = await this.#startPromise;
    return this.#public(h);
  }

  /**
   * Run `fn` against a ready serve, tracking it as in-flight so the idle timer
   * never kills a serve mid-call. In per-call mode the serve is killed when `fn`
   * returns (or throws); otherwise the idle timer is (re)armed once idle.
   *
   * A serve that dies mid-call surfaces as `fn`'s own error — it is NOT swallowed
   * or retried here; only an idle death is revived (on the next call).
   */
  async withServe<T>(fn: (h: ServeHandle) => Promise<T>): Promise<T> {
    this.#clearIdleTimer();
    this.#inFlight += 1;
    try {
      const handle = await this.ensureServe();
      return await fn(handle);
    } finally {
      this.#inFlight -= 1;
      if (this.#inFlight === 0) {
        if (this.#perCall) {
          this.shutdown("per-call");
        } else {
          this.#armIdleTimer();
        }
      }
    }
  }

  /** Kill the serve child and clear all timers. Idempotent. */
  shutdown(_reason?: string): void {
    this.#clearIdleTimer();
    const h = this.#handle;
    this.#handle = undefined;
    this.#startPromise = undefined;
    killServe(h?.proc);
  }

  /**
   * Wire the PRIMARY shutdown triggers: stdin end/close and the MCP transport's
   * onclose. These are what actually fire under Claude Code teardown. Signals and
   * process `exit` are installed here too, but only as a second layer.
   *
   * `exitProcess` (server use) exits the process after shutdown on a stdin/transport
   * trigger; tests pass a fake stdin with `exitProcess:false` to observe shutdown.
   */
  attachShutdownTriggers(
    sources: { stdin?: Readable; transport?: { onclose?: (() => void) | undefined } },
    opts: { exitProcess?: boolean } = {},
  ): void {
    // Idempotent: a second call must not stack another stdin 'end'/'close' listener
    // or re-wrap (and re-chain) transport.onclose, so calling this more than once is
    // a harmless no-op rather than a double-shutdown hazard.
    if (this.#triggersAttached) return;
    this.#installBackstop();
    const exitProcess = opts.exitProcess ?? false;

    const trigger = (reason: string) => {
      this.shutdown(reason);
      if (exitProcess) process.exit(0);
    };

    const { stdin, transport } = sources;
    if (stdin) {
      // `resume()` guarantees the stream reaches 'end' on EOF even if nothing else
      // is consuming it yet; the MCP transport's own 'data' listener also keeps it
      // flowing, and both listeners coexist.
      stdin.on("end", () => trigger("stdin-end"));
      stdin.on("close", () => trigger("stdin-close"));
      stdin.resume();
    }
    if (transport) {
      const prev = transport.onclose;
      transport.onclose = () => {
        try {
          prev?.();
        } finally {
          trigger("transport-close");
        }
      };
    }
    this.#triggersAttached = true;
  }

  get triggersAttached(): boolean {
    return this.#triggersAttached;
  }

  // --- internals ------------------------------------------------------------
  #public(h: InternalHandle): ServeHandle {
    return { baseUrl: h.baseUrl, port: h.port, pid: h.pid };
  }

  #clearIdleTimer(): void {
    if (this.#idleTimer) {
      clearTimeout(this.#idleTimer);
      this.#idleTimer = undefined;
    }
  }

  #armIdleTimer(): void {
    this.#clearIdleTimer();
    if (this.#idleMs <= 0 || this.#perCall) return;
    this.#idleTimer = setTimeout(() => {
      if (this.#inFlight === 0) this.shutdown("idle");
    }, this.#idleMs);
    // Don't let a pending idle timer keep the process alive on its own.
    this.#idleTimer.unref();
  }

  /** Synchronous, second-layer backstop: kill the child on any process exit/signal. */
  #installBackstop(): void {
    if (this.#backstopInstalled) return;
    this.#backstopInstalled = true;

    process.on("exit", () => killServe(this.#handle?.proc));

    const signals: NodeJS.Signals[] = ["SIGINT", "SIGTERM", "SIGHUP"];
    for (const sig of signals) {
      process.on(sig, () => {
        killServe(this.#handle?.proc);
        process.exit(sig === "SIGINT" ? 130 : sig === "SIGTERM" ? 143 : 129);
      });
    }
  }

  async #start(): Promise<InternalHandle> {
    this.#installBackstop();
    const port = await pickFreePort(this.#host);
    const baseUrl = `http://${this.#host}:${port}`;

    const proc = spawn(
      "opencode",
      ["serve", "--port", String(port), "--hostname", this.#host],
      {
        cwd: this.#projectDir,
        detached: true, // own process group → killable as a unit
        stdio: ["ignore", "ignore", "ignore"],
        env: { ...process.env },
      },
    );
    if (proc.pid === undefined) {
      throw new Error("failed to spawn `opencode serve` (no pid)");
    }

    const handle: InternalHandle = { proc, baseUrl, port, pid: proc.pid, exited: false };

    // Mark the handle exited so ensureServe() crash-revives on the next call, and
    // so isRunning reflects reality without an extra probe.
    proc.on("exit", () => {
      handle.exited = true;
      if (this.#handle === handle) this.#handle = undefined;
    });

    // Poll GET /doc until the server answers or we time out (readiness contract).
    const deadline = Date.now() + this.#readyTimeoutMs;
    for (;;) {
      if (handle.exited) {
        throw new Error(`opencode serve exited before becoming ready (cwd=${this.#projectDir})`);
      }
      try {
        const res = await fetch(`${baseUrl}/doc`, { signal: AbortSignal.timeout(READY_HTTP_MS) });
        if (res.ok) break;
      } catch {
        /* not up yet */
      }
      if (Date.now() > deadline) {
        killServe(proc);
        throw new Error(`opencode serve did not become ready within ${this.#readyTimeoutMs}ms`);
      }
      await new Promise((r) => setTimeout(r, READY_POLL_MS));
    }

    this.#handle = handle;
    return handle;
  }
}
