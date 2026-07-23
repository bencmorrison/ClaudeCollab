/**
 * A standalone log writer, spawned as a child PROCESS by log.test.ts's concurrency
 * cases (C34). It appends a full expect→started→completed lifecycle for one
 * call_id under the run named by the environment, holding briefly BETWEEN appends so its
 * lifetime overlaps its siblings', then prints its own wall-clock start/end so the parent
 * can PROVE the writers ran simultaneously rather than in series.
 *
 * Run as a separate process on purpose: the mkdir lock's cross-process serialization is
 * only exercised when writers genuinely race. The hold (GUILD_TEST_HOLD_MS) happens
 * OUTSIDE the lock, so it does not block a sibling's append — it only guarantees the
 * children are alive at the same time, which is the overlap the parent asserts.
 *
 * Output (stdout, one line): `START <ms> END <ms>` (epoch milliseconds).
 * Env: GUILD_LOG_DIR, GUILD_RUN_ID, CHILD_CALL_ID, GUILD_TEST_HOLD_MS.
 */

import { EvidenceLog } from "../src/log.js";

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function main(): Promise<void> {
  const callId = process.env.CHILD_CALL_ID ?? "child";
  const hold = Number(process.env.GUILD_TEST_HOLD_MS ?? "120");
  const log = new EvidenceLog({ env: process.env });
  const start = Date.now();
  await log.expect({ callId, command: "/guild:panel", model: "m/x", agent: "guild-read" });
  await sleep(hold);
  const st = await log.started({
    callId,
    command: "/guild:panel",
    model: "m/x",
    agent: "guild-read",
    prompt: `prompt for ${callId}`,
  });
  await sleep(hold);
  await log.completed({
    callId,
    exit: 0,
    turn: st.turn,
    command: "/guild:panel",
    model: "m/x",
    agent: "guild-read",
    captureState: "complete",
    response: `answer for ${callId}`,
  });
  const end = Date.now();
  process.stdout.write(`START ${start} END ${end}\n`);
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error("log-writer-child failed:", err);
    process.exit(1);
  },
);
