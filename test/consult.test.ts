/**
 * collab_consult tests (PLAN.md M5; CONTRACT.md C1–C7, C12, C22–C25, C31, C41, C45)
 * — OFFLINE.
 *
 * No model is called: the model turn is served by the `node:http` fake
 * (test/fake-opencode-server.ts) behind a `ServeProvider`, exactly like the M2 client
 * tests. The evidence layer writes to a temp COLLAB_LOG_DIR, and the flagship case
 * verifies a TOOL-PRODUCED run with the TS `verify()` (the reference verifier; the bash
 * `collab/log.sh verify` it was cross-checked against retired at M12).
 */

import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  readdirSync,
  existsSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  consult,
  consultToToolResult,
  collabDoctorSeed,
  type ConsultResult,
} from "../src/consult.js";
import { EvidenceLog } from "../src/log.js";
import { startFakeOpencode, type FakeOpencode } from "./fake-opencode-server.js";
import type { ServeProvider } from "../src/client.js";
import type { ServeHandle } from "../src/lifecycle.js";
import { Checker } from "./harness.js";

const SHA256_EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/** A `ServeProvider` pointing `withServe` at an already-running fake (no opencode). */
function fakeServe(fake: FakeOpencode): ServeProvider {
  const handle: ServeHandle = { baseUrl: fake.baseUrl, port: 0, pid: 0 };
  return { withServe: (fn) => fn(handle) };
}

const tmpDirs: string[] = [];
function tmp(prefix = "m5-"): string {
  const d = mkdtempSync(path.join(tmpdir(), prefix));
  tmpDirs.push(d);
  return d;
}

/** A collab root carrying a deny/ask test policy; returns its path. */
function makeCollabRoot(): string {
  const root = tmp("m5-collab-");
  writeFileSync(
    path.join(root, "models.policy.local"),
    "# M5 test policy\ndeny openai/denied-model\nask openai/ask-model\n",
  );
  return root;
}

/** A clean env: process.env minus every COLLAB_* knob, then the given overrides. */
function envWith(overrides: Record<string, string>): NodeJS.ProcessEnv {
  const base: NodeJS.ProcessEnv = { ...process.env };
  for (const k of Object.keys(base)) if (k.startsWith("COLLAB_")) delete base[k];
  return { ...base, ...overrides };
}

/** An awkward answer that exposes every classic capture bug (from client.test). */
const AWKWARD =
  'line one\n"quoted" value\ttab\ncafé ☕ — naïve façade\n{"json":true}\ntrailing-newline-follows\n';

function readEntries(logDir: string, runId: string): Array<Record<string, unknown>> {
  const file = path.join(logDir, runId, "calls.jsonl");
  return readFileSync(file, "utf8")
    .split("\n")
    .filter((l) => l.length > 0)
    .map((l) => JSON.parse(l) as Record<string, unknown>);
}

export async function run(): Promise<number> {
  const c = new Checker();
  console.log("== consult.test (M5 collab_consult) ==");

  // -------------------------------------------------------------------------
  // 1. Policy DENY → structured error (exit-3 analogue); NOTHING logged (C7/C24).
  // -------------------------------------------------------------------------
  {
    const root = makeCollabRoot();
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir });
    const fake = await startFakeOpencode({ historyText: "should never be reached" });
    try {
      const r = await consult(
        { question: "hi", model: "openai/denied-model" },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(!r.ok, "deny: consult refuses");
      if (!r.ok) {
        c.check(r.error.kind === "policy-deny", "deny: error kind is policy-deny");
        c.check(r.error.exitAnalogue === 3, "deny: exit analogue is 3");
        c.check(r.error.tier === "deny", "deny: tier reported as deny");
        c.check(r.error.message.includes("openai/denied-model"), "deny: message names the model");
      }
      c.check(fake.recorded.messageBodies.length === 0, "deny: no model call was made");
      c.check(readdirSync(logDir).length === 0, "deny: NOTHING logged (no run dir created)");
    } finally {
      await fake.close();
    }
  }

  // -------------------------------------------------------------------------
  // 2. ASK unconfirmed → structured ask error (exit-4 analogue); NOTHING logged.
  //    The error text must instruct the DRIVER to ask the human and retry with
  //    confirmed:true (C41 two-layer defense).
  // -------------------------------------------------------------------------
  {
    const root = makeCollabRoot();
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir });
    const fake = await startFakeOpencode({ historyText: "unreached" });
    try {
      const r = await consult(
        { question: "hi", model: "openai/ask-model" },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(!r.ok, "ask: consult refuses when not confirmed");
      if (!r.ok) {
        c.check(r.error.kind === "policy-ask", "ask: error kind is policy-ask");
        c.check(r.error.exitAnalogue === 4, "ask: exit analogue is 4");
        c.check(
          /confirmed:true/.test(r.error.message) && /ask the user/i.test(r.error.message),
          "ask: message tells the DRIVER to ask the human and retry with confirmed:true",
        );
        c.check(
          /not set confirmed yourself|approval, not yours/i.test(r.error.message),
          "ask: message forbids the assistant self-confirming",
        );
      }
      c.check(fake.recorded.messageBodies.length === 0, "ask: no model call was made");
      c.check(readdirSync(logDir).length === 0, "ask: NOTHING logged");
    } finally {
      await fake.close();
    }
  }

  // -------------------------------------------------------------------------
  // 3. ASK + confirmed:true → proceeds (the user-approval analogue of COLLAB_CONFIRMED).
  // -------------------------------------------------------------------------
  {
    const root = makeCollabRoot();
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir, COLLAB_LOG_PROMPTS: "full" });
    const fake = await startFakeOpencode({ historyText: "approved answer" });
    try {
      const r = await consult(
        { question: "hi", model: "openai/ask-model", confirmed: true },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(r.ok, "ask+confirmed: consult proceeds");
      if (r.ok) {
        c.check(r.answer === "approved answer", "ask+confirmed: answer returned");
        c.check(fake.recorded.messageBodies.length === 1, "ask+confirmed: the model was called");
        c.check(new EvidenceLog({ env }).verify(r.attribution.runId).code === 0, "ask+confirmed: run verifies clean");
        // fix 2: the ask-tier + approval audit trail is recorded on started AND completed.
        const entries = readEntries(logDir, r.attribution.runId);
        const started = entries.find((e) => e.type === "call" && e.status === "started");
        const completed = entries.find((e) => e.type === "call" && e.status === "completed");
        c.check(started?.tier === "ask" && started?.confirmed === true, "ask+confirmed: started records tier=ask, confirmed=true");
        c.check(completed?.tier === "ask" && completed?.confirmed === true, "ask+confirmed: completed records tier=ask, confirmed=true");
        c.check(new EvidenceLog({ env }).verify(r.attribution.runId).code === 0, "ask+confirmed: verify accepts entries carrying the tier/confirmed fields");
      }
    } finally {
      await fake.close();
    }
  }

  // -------------------------------------------------------------------------
  // 4. FLAGSHIP: allow → full lifecycle logged; a TOOL-PRODUCED run passes TS verify().
  //    This is the receipts guarantee — every real call leaves a verifiable record.
  // -------------------------------------------------------------------------
  {
    const root = makeCollabRoot();
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir, COLLAB_LOG_PROMPTS: "full" });
    const fake = await startFakeOpencode({ historyText: "the second opinion", syncText: "SYNC-MUST-NOT-LEAK" });
    try {
      const r = await consult(
        { question: "review my plan\n", model: "openai/allow-model" },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(r.ok, "allow: consult proceeds");
      if (r.ok) {
        const runId = r.attribution.runId;
        c.check(runId.length > 0, "allow: a run id was minted");
        c.check(r.answer === "the second opinion", "allow: answer is the history text (not the sync body)");
        c.check(r.attribution.agent === "collab-read", "allow: attribution names the UNMODIFIED collab-read agent");
        c.check(r.attribution.model === "openai/allow-model", "allow: exact-id attribution (C45)");
        c.check(r.attribution.callId.length > 0, "allow: a call id is attributed");

        // Entry lifecycle: exactly expected → started → completed for one call_id.
        const entries = readEntries(logDir, runId);
        const cid = r.attribution.callId;
        const forCall = entries.filter((e) => e.call_id === cid);
        c.check(forCall.length === 3, "allow: three lifecycle entries for the call");
        c.check(entries.some((e) => e.type === "expected-call" && e.call_id === cid), "allow: expected-call written");
        c.check(entries.some((e) => e.type === "call" && e.status === "started" && e.call_id === cid), "allow: started written");
        const completed = entries.find((e) => e.type === "call" && e.status === "completed" && e.call_id === cid);
        c.check(!!completed && completed.capture_state === "complete", "allow: completed with capture_state complete");
        c.check(!!completed && completed.raw_response === "the second opinion", "allow: byte-exact raw_response recorded");
        // fix 2: allow-tier entries carry tier="allow", confirmed=false (present, not omitted).
        const startedEntry = entries.find((e) => e.type === "call" && e.status === "started" && e.call_id === cid);
        c.check(startedEntry?.tier === "allow" && startedEntry?.confirmed === false, "allow: started records tier=allow, confirmed=false");
        c.check(completed?.tier === "allow" && completed?.confirmed === false, "allow: completed records tier=allow, confirmed=false");

        // verify on the tool-produced run.
        const tsCode = new EvidenceLog({ env }).verify(runId).code;
        c.check(tsCode === 0, "FLAGSHIP: TS verify() passes the tool-produced run (code 0)");
      }
    } finally {
      await fake.close();
    }
  }

  // -------------------------------------------------------------------------
  // 5. Byte-exact answer round-trip THROUGH THE TOOL BOUNDARY (MCP serialization).
  // -------------------------------------------------------------------------
  {
    const root = makeCollabRoot();
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir });
    const fake = await startFakeOpencode({ historyText: AWKWARD });
    try {
      const r = await consult(
        { question: "q", model: "openai/allow-model" },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(r.ok && r.answer === AWKWARD, "boundary: consult answer is byte-exact");
      // Translate to the MCP wire shape and round-trip it through JSON (what stdio does).
      const wire = consultToToolResult(r);
      const roundTripped = JSON.parse(JSON.stringify(wire)) as {
        content: Array<{ text: string }>;
        structuredContent: { answer: string };
      };
      const textOut = roundTripped.content[0].text;
      const structOut = roundTripped.structuredContent.answer;
      c.check(textOut === AWKWARD, "boundary: content text survives JSON round-trip byte-exact");
      c.check(structOut === AWKWARD, "boundary: structuredContent.answer survives byte-exact");
      c.check(
        Buffer.from(textOut, "utf8").equals(Buffer.from(AWKWARD, "utf8")),
        "boundary: utf8 buffer identical (newlines/quotes/unicode/trailing-newline)",
      );
    } finally {
      await fake.close();
    }
  }

  // -------------------------------------------------------------------------
  // 6. Empty-but-present answer stays COMPLETE (raw_response "", hash = sha256("")).
  // -------------------------------------------------------------------------
  {
    const root = makeCollabRoot();
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir });
    const fake = await startFakeOpencode({ historyText: "" });
    try {
      const r = await consult(
        { question: "q", model: "openai/allow-model" },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(r.ok && r.answer === "", "empty: a present-but-empty answer returns ''");
      if (r.ok) {
        const completed = readEntries(logDir, r.attribution.runId).find(
          (e) => e.type === "call" && e.status === "completed",
        );
        c.check(!!completed && completed.capture_state === "complete", "empty: stays complete (not downgraded to failed)");
        c.check(!!completed && completed.response_hash === SHA256_EMPTY, "empty: response_hash is sha256(\"\")");
        c.check(new EvidenceLog({ env }).verify(r.attribution.runId).code === 0, "empty: run verifies clean");
      }
    } finally {
      await fake.close();
    }
  }

  // -------------------------------------------------------------------------
  // 7. Model-call failure → completed/failed logged + tool error (no fabricated answer).
  //    The expected-call gap stays closed (started+completed present); capture_state
  //    failed makes verify() fail LOUDLY (code 7), as designed (C25/C40).
  // -------------------------------------------------------------------------
  {
    const root = makeCollabRoot();
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir });
    const fake = await startFakeOpencode({ historyText: "x", failMessage: true });
    try {
      const r = await consult(
        { question: "q", model: "openai/allow-model" },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(!r.ok, "fail: consult returns a tool error");
      if (!r.ok) {
        c.check(r.error.kind === "call-failed", "fail: error kind is call-failed");
        // fix 1: exitAnalogue must be null, NEVER 0 (0 collides with C53 success).
        c.check(r.error.exitAnalogue === null, "fail: call-failed exitAnalogue is null (never 0)");
        c.check(!/answer/i.test(r.error.message) || /No answer was produced/.test(r.error.message), "fail: no fabricated answer");
        // The run still has exactly one started + one completed (gap closed).
        const runId = new EvidenceLog({ env }).latest();
        c.check(!!runId, "fail: a run was created (newRun before the call)");
        if (runId) {
          const entries = readEntries(logDir, runId);
          const started = entries.filter((e) => e.type === "call" && e.status === "started");
          const completed = entries.filter((e) => e.type === "call" && e.status === "completed");
          c.check(started.length === 1 && completed.length === 1, "fail: expected-call gap closed (1 started, 1 completed)");
          c.check(completed[0]?.capture_state === "failed", "fail: completed records capture_state failed");
          c.check(new EvidenceLog({ env }).verify(runId).code === 7, "fail: verify fails LOUDLY on the failed capture (code 7)");
        }
      }
    } finally {
      await fake.close();
    }
  }

  // -------------------------------------------------------------------------
  // 8. runId threading: two calls, one run, DISTINCT call_ids, cardinality verifies.
  // -------------------------------------------------------------------------
  {
    const root = makeCollabRoot();
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir, COLLAB_LOG_PROMPTS: "full" });
    const fake = await startFakeOpencode({ historyText: "answer" });
    try {
      const r1 = await consult(
        { question: "first", model: "openai/allow-model" },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(r1.ok, "thread: first call ok");
      const runId = r1.ok ? r1.attribution.runId : "";
      const r2 = await consult(
        { question: "second", model: "openai/allow-model", runId },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(r2.ok, "thread: second call ok");
      if (r1.ok && r2.ok) {
        c.check(r2.attribution.runId === runId, "thread: second call reused the same run");
        c.check(r1.attribution.callId !== r2.attribution.callId, "thread: the two calls have distinct call_ids");
        const entries = readEntries(logDir, runId);
        const expected = entries.filter((e) => e.type === "expected-call");
        c.check(expected.length === 2, "thread: two expected-call entries in one run");
        c.check(new EvidenceLog({ env }).verify(runId).code === 0, "thread: the two-call run verifies (cardinality both directions)");
      }
    } finally {
      await fake.close();
    }
  }

  // -------------------------------------------------------------------------
  // 9. Multi-root conflict surfaces in collab_status (the M4 "doctor MUST warn").
  // -------------------------------------------------------------------------
  {
    // Two roots on disk: <cwd>/collab and <home>/.claude/collab, no COLLAB_ROOT.
    const cwd = tmp("m5-proj-");
    mkdirSync(path.join(cwd, "collab"), { recursive: true });
    const home = tmp("m5-home-");
    mkdirSync(path.join(home, ".claude", "collab"), { recursive: true });
    const env = envWith({}); // no COLLAB_ROOT

    const seed = collabDoctorSeed(env, cwd, home);
    c.check(seed.collabRoot.source === "project", "conflict: the project root wins");
    c.check(typeof seed.collabRoot.conflict === "string", "conflict: a conflict warning is surfaced");
    if (typeof seed.collabRoot.conflict === "string") {
      c.check(seed.collabRoot.conflict.includes(path.join(cwd, "collab")), "conflict: names the winning root");
      c.check(
        seed.collabRoot.conflict.includes(path.join(home, ".claude", "collab")) &&
          /shadow/i.test(seed.collabRoot.conflict),
        "conflict: names the shadowed root",
      );
    }
    c.check(typeof seed.policy.file === "string" && seed.policy.file.length > 0, "conflict: policy file + source reported");
    c.check(typeof seed.logging.enabled === "boolean" && typeof seed.logging.logDir === "string", "conflict: logging on/off + log dir reported");

    // Single root → no conflict.
    const single = collabDoctorSeed(envWith({ COLLAB_ROOT: path.join(cwd, "collab") }), cwd, home);
    c.check(single.collabRoot.conflict === null, "conflict: an explicit single root reports no conflict");
  }

  // -------------------------------------------------------------------------
  // 10. Leading-dash model PARAM → model-id error (exit-2 analogue); zero log entries.
  //     Refused before any log write, exactly like a policy refusal (C12/C24).
  // -------------------------------------------------------------------------
  {
    const root = makeCollabRoot();
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir });
    const fake = await startFakeOpencode({ historyText: "unreached" });
    try {
      const r = await consult(
        { question: "q", model: "-oh-no" },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(!r.ok, "dash-param: consult refuses a leading-dash model id");
      if (!r.ok) {
        c.check(r.error.kind === "model-id", "dash-param: error kind is model-id");
        c.check(r.error.exitAnalogue === 2, "dash-param: exit analogue is 2");
      }
      c.check(fake.recorded.messageBodies.length === 0, "dash-param: no model call made");
      c.check(readdirSync(logDir).length === 0, "dash-param: ZERO log entries");
    } finally {
      await fake.close();
    }
  }

  // -------------------------------------------------------------------------
  // 11. COLLAB_LOG=off + a THROWING serve → no crash; call-failed returned; nothing
  //     logged (logging disabled means every log hook short-circuits, C31 posture).
  // -------------------------------------------------------------------------
  {
    const root = makeCollabRoot();
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir, COLLAB_LOG: "off" });
    const fake = await startFakeOpencode({ historyText: "x", failMessage: true });
    try {
      let threw = false;
      let r: ConsultResult | undefined;
      try {
        r = await consult(
          { question: "q", model: "openai/allow-model" },
          { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
        );
      } catch {
        threw = true;
      }
      c.check(!threw, "log-off: consult does not crash when logging is off and the serve throws");
      c.check(!!r && !r.ok && r.error.kind === "call-failed", "log-off: call-failed returned");
      c.check(!!r && !r.ok && r.error.exitAnalogue === null, "log-off: exitAnalogue null");
      c.check(readdirSync(logDir).length === 0, "log-off: nothing written (logging disabled)");
    } finally {
      await fake.close();
    }
  }

  // -------------------------------------------------------------------------
  // 12. Double refusal (leading-dash AND deny-tier) → model-id wins DETERMINISTICALLY.
  //     The model-id check runs before the policy gate, so a dash-leading id is refused
  //     as model-id even when a `deny -*` rule would also match it.
  // -------------------------------------------------------------------------
  {
    const root = tmp("m5-collab-");
    // `deny -*` would ALSO deny the dash-leading id — but model-id is checked first.
    writeFileSync(path.join(root, "models.policy.local"), "# double-refusal\ndeny -*\n");
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir });
    const fake = await startFakeOpencode({ historyText: "unreached" });
    try {
      const r = await consult(
        { question: "q", model: "-denied-and-dashed" },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(!r.ok, "double: consult refuses");
      if (!r.ok) {
        c.check(r.error.kind === "model-id", "double: model-id wins (checked before policy), NOT policy-deny");
        c.check(r.error.exitAnalogue === 2, "double: exit analogue is 2 (model-id), deterministically");
      }
      c.check(readdirSync(logDir).length === 0, "double: nothing logged");
    } finally {
      await fake.close();
    }
  }

  // -------------------------------------------------------------------------
  // Session continuation (M7 / Option B): consult keepSession → id returned + session
  // KEPT; a follow-up consult threads that sessionId (no re-transmitting the peer's
  // words) and carries the session id on BOTH its started and completed entries; the
  // one threaded run verifies under verify with session ids present.
  // -------------------------------------------------------------------------
  {
    const root = tmp("m5-collab-"); // no policy ⇒ default-allow
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir, COLLAB_LOG_PROMPTS: "full" });
    const fake = await startFakeOpencode({ historyText: "turn answer" });
    try {
      // Round 1: keepSession → session id returned, session NOT deleted yet.
      const r1 = await consult(
        { question: "round 1 question", model: "openai/gpt-fake", keepSession: true },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(r1.ok, "session: round-1 consult ok");
      const runId = r1.ok ? r1.attribution.runId : "";
      const sid = r1.ok ? r1.sessionId : undefined;
      c.check(!!sid && sid === "ses_fake", "session: keepSession returned the session id");
      c.check(fake.recorded.deletes.length === 0, "session: round-1 kept the session (no delete)");
      const wire1 = consultToToolResult(r1);
      c.check(
        (wire1.structuredContent as Record<string, unknown>)?.sessionId === "ses_fake",
        "session: MCP result surfaces the kept sessionId",
      );

      // Round 2: CONTINUE that session (sessionId only — the peer's prior turn is NOT
      // re-sent), threaded into the same run.
      const r2 = await consult(
        { question: "round 2 — my new turn only", model: "openai/gpt-fake", runId, sessionId: sid },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(r2.ok, "session: round-2 continuation ok");
      c.check(fake.recorded.createBodies.length === 1, "session: continuation made NO new create (still just round-1's)");
      c.check(fake.recorded.messageBodies.length === 2, "session: two turns total went to the session");
      c.check(fake.recorded.deletes.length === 1 && fake.recorded.deletes[0] === "ses_fake", "session: round-2 (keepSession off) deleted the continued session once");

      // The continuation's started AND completed both carry the session id.
      const call2Id = r2.ok ? r2.attribution.callId : "";
      const entries = readEntries(logDir, runId);
      const started2 = entries.find((e) => e.call_id === call2Id && e.status === "started");
      const completed2 = entries.find((e) => e.call_id === call2Id && e.status === "completed");
      c.check(started2?.session_id === "ses_fake", "session: round-2 STARTED entry carries session_id");
      c.check(completed2?.session_id === "ses_fake", "session: round-2 COMPLETED entry carries session_id");

      // The single threaded run verifies under verify, session ids present.
      c.check(new EvidenceLog({ env }).verify(runId).code === 0, "session: threaded run passes TS verify()");
    } finally {
      await fake.close();
    }
  }

  // -------------------------------------------------------------------------
  // Agent MISMATCH (positive-direction over bash C16): opencode serves a DIFFERENT
  // agent than requested → fail closed. No answer returned; completed recorded as
  // capture_state:failed; the run is still well-formed (verify passes — a failed
  // capture is legitimate, an unpaired entry is not).
  // -------------------------------------------------------------------------
  {
    const root = tmp("m5-collab-"); // default-allow
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir, COLLAB_LOG_PROMPTS: "full" });
    const fake = await startFakeOpencode({ historyText: "FULL-ACCESS ANSWER", servedAgent: "build" });
    try {
      const r = await consult(
        { question: "q", model: "openai/gpt-fake" },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(!r.ok, "mismatch: consult fails closed");
      if (!r.ok) {
        c.check(r.error.kind === "agent-mismatch", "mismatch: kind is agent-mismatch");
        c.check(r.error.message.includes("collab-read") && r.error.message.includes("build"), "mismatch: message names requested (collab-read) and served (build)");
        c.check(!("answer" in r), "mismatch: NO answer field on the failure result");
      }
      const wire = consultToToolResult(r);
      c.check(wire.isError === true, "mismatch: MCP result flags isError");
      c.check(!wire.content[0].text.includes("FULL-ACCESS ANSWER"), "mismatch: the wrong-agent answer is NOT surfaced");

      // The run recorded exactly one started + one completed(failed). A failed capture is
      // a real evidence GAP: verify must FLAG it (code 7), not report clean — the witness
      // has to see the wrong-agent call failed, never a false all-good. (The `latest`
      // symlink also lives in logDir, so filter it out to find the single run dir.)
      const dirs = readdirSync(logDir).filter((d) => d !== "latest");
      c.check(dirs.length === 1, "mismatch: exactly one run dir was written (call gated-open, then failed closed)");
      const rid = dirs[0];
      const entries = readEntries(logDir, rid);
      const completed = entries.find((e) => e.type === "call" && e.status === "completed");
      c.check(completed?.capture_state === "failed", "mismatch: completed entry is capture_state:failed");
      c.check(completed?.raw_response === "", "mismatch: NO wrong-agent response captured");
      c.check(new EvidenceLog({ env }).verify(rid).code === 7, "mismatch: verify FLAGS the failed capture (code 7) — the gap is visible");
    } finally {
      await fake.close();
    }
  }

  // MATCH: served agent equals requested → normal success (the check is not a false trip).
  {
    const root = tmp("m5-collab-");
    const logDir = tmp("m5-logs-");
    const env = envWith({ COLLAB_ROOT: root, COLLAB_LOG_DIR: logDir });
    const fake = await startFakeOpencode({ historyText: "read-only answer", servedAgent: "collab-read" });
    try {
      const r = await consult(
        { question: "q", model: "openai/gpt-fake" },
        { serve: fakeServe(fake), env, messageTimeoutMs: 5_000 },
      );
      c.check(r.ok, "match: consult succeeds when the served agent matches");
      c.check(r.ok && r.answer === "read-only answer", "match: the answer is returned");
    } finally {
      await fake.close();
    }
  }

  // cleanup
  for (const d of tmpDirs) {
    try {
      if (existsSync(d)) rmSync(d, { recursive: true, force: true });
    } catch {
      /* best-effort */
    }
  }

  console.log(`consult.test: ${c.passes} passed, ${c.failures} failed`);
  return c.failures;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  run().then((f) => process.exit(f > 0 ? 1 : 0));
}
