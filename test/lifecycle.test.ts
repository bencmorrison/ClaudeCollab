/**
 * Lifecycle supervisor tests (PLAN.md M1): clean spawn→ready→shutdown, idle timeout,
 * crash-revive, and per-call mode. In-process against the real `opencode serve`
 * (free — no model call). Every wait is bounded.
 */

import { OpencodeLifecycle, type ServeHandle } from "../src/lifecycle.js";
import { Checker, pidAlive, waitFor, withTimeout, sleep } from "./harness.js";

const SPAWN_MS = 40_000;

/** A trivial, model-free "call": prove the handle points at a live serve. */
async function poke(h: ServeHandle): Promise<void> {
  const res = await fetch(`${h.baseUrl}/doc`, { signal: AbortSignal.timeout(5_000) });
  if (!res.ok) throw new Error(`/doc → ${res.status}`);
}

export async function run(): Promise<number> {
  const c = new Checker();
  console.log("== lifecycle.test ==");

  // 1. clean spawn → ready → shutdown -----------------------------------------
  {
    const lc = new OpencodeLifecycle({ idleMs: 0 });
    const h = await withTimeout(lc.ensureServe(), SPAWN_MS, "clean:ensureServe");
    c.check(lc.isRunning, "clean: isRunning after ensureServe");
    c.check(typeof h.port === "number" && h.port > 0, "clean: handle has a port");
    c.check(lc.pid === h.pid && pidAlive(h.pid), "clean: pid reported and alive");
    await poke(h);
    c.check(true, "clean: /doc answered on the negotiated port");
    const pid = h.pid;
    lc.shutdown("test");
    c.check(!lc.isRunning, "clean: isRunning false after shutdown");
    c.check(await waitFor(() => !pidAlive(pid), 8_000), "clean: serve pid dead after shutdown");
  }

  // 2. idle timeout fires ------------------------------------------------------
  {
    const lc = new OpencodeLifecycle({ idleMs: 800 });
    const pid = await withTimeout(
      lc.withServe(async (h) => {
        await poke(h);
        return h.pid;
      }),
      SPAWN_MS,
      "idle:withServe",
    );
    c.check(lc.isRunning, "idle: serve still up immediately after the call (timer armed)");
    const died = await waitFor(() => !pidAlive(pid), 6_000);
    c.check(died, "idle: serve killed after the idle timeout elapsed");
    c.check(!lc.isRunning, "idle: isRunning false once idle-killed");
    lc.shutdown();
  }

  // 3. crash-revive: idle death → next call respawns ---------------------------
  {
    const lc = new OpencodeLifecycle({ idleMs: 0 });
    const h1 = await withTimeout(lc.ensureServe(), SPAWN_MS, "revive:ensureServe1");
    const pid1 = h1.pid;
    // Simulate a crash while idle: kill the serve out from under the manager.
    try {
      process.kill(-pid1, "SIGKILL");
    } catch {
      process.kill(pid1, "SIGKILL");
    }
    c.check(await waitFor(() => !pidAlive(pid1), 8_000), "revive: original serve is dead");
    c.check(await waitFor(() => !lc.isRunning, 4_000), "revive: manager observed the exit (isRunning false)");
    const h2 = await withTimeout(lc.ensureServe(), SPAWN_MS, "revive:ensureServe2");
    c.check(h2.pid !== pid1 && pidAlive(h2.pid), "revive: next ensureServe respawned a fresh, live serve");
    lc.shutdown();
    c.check(await waitFor(() => !pidAlive(h2.pid), 8_000), "revive: revived serve dead after shutdown");
  }

  // 4. per-call mode: spawn and kill per call ----------------------------------
  {
    const lc = new OpencodeLifecycle({ perCall: true });
    let seenRunning = false;
    const pid1 = await withTimeout(
      lc.withServe(async (h) => {
        await poke(h);
        seenRunning = lc.isRunning;
        return h.pid;
      }),
      SPAWN_MS,
      "percall:withServe1",
    );
    c.check(seenRunning, "per-call: serve was up during the call");
    c.check(await waitFor(() => !pidAlive(pid1), 8_000), "per-call: serve killed when the call returned");
    c.check(!lc.isRunning, "per-call: isRunning false between calls");

    const pid2 = await withTimeout(
      lc.withServe(async (h) => {
        await poke(h);
        return h.pid;
      }),
      SPAWN_MS,
      "percall:withServe2",
    );
    c.check(pid2 !== pid1, "per-call: second call spawned a fresh serve (new pid)");
    c.check(await waitFor(() => !pidAlive(pid2), 8_000), "per-call: second serve killed when its call returned");
    lc.shutdown();
  }

  await sleep(50);
  console.log(`lifecycle.test: ${c.passes} passed, ${c.failures} failed`);
  return c.failures;
}

// Allow standalone execution: `tsx test/lifecycle.test.ts`.
if (import.meta.url === `file://${process.argv[1]}`) {
  run().then((f) => process.exit(f > 0 ? 1 : 0));
}
