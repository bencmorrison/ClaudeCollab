/**
 * Evidence-layer tests (CONTRACT.md area D, C22–C35) — OFFLINE.
 *
 * No model is called. The suite drives `src/log.ts` (the reference implementation; the
 * bash `collab/log.sh` it was cross-verified against retired at M12). Canonicalization is
 * still pinned byte-for-byte against `jq` (a system tool, not a ClaudeCollab script), and
 * cross-process concurrency is proven with genuinely-racing TS writer child processes
 * (`test/log-writer-child.ts`) contending the shared `mkdir` lock.
 */

import { execFileSync, spawnSync, spawn } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  existsSync,
  rmSync,
  utimesSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  EvidenceLog,
  confGet,
  type PromptMode,
} from "../src/log.js";
import { canonicalStringify, buildEntryLine } from "../src/canonical.js";
import { Checker, repoRoot, tsxBin, sleep } from "./harness.js";

const CHILD = path.join(repoRoot, "test", "log-writer-child.ts");

/** A fresh temp dir, cleaned at suite end. */
const tmpDirs: string[] = [];
function tmp(prefix = "m3log-"): string {
  const d = mkdtempSync(path.join(tmpdir(), prefix));
  tmpDirs.push(d);
  return d;
}

function envFor(logDir: string, extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  return { ...process.env, COLLAB_LOG_DIR: logDir, ...extra } as NodeJS.ProcessEnv;
}

function lines(file: string): string[] {
  return readFileSync(file, "utf8").split("\n").filter((l) => l.length > 0);
}
function parsed(file: string): Array<Record<string, unknown>> {
  return lines(file).map((l) => JSON.parse(l) as Record<string, unknown>);
}

export async function run(): Promise<number> {
  const c = new Checker();
  console.log("== log.test (evidence layer, M3) ==");

  // -------------------------------------------------------------------------
  // 0. Canonicalization byte-match against jq (the heart of the milestone).
  // -------------------------------------------------------------------------
  {
    // Every entry field type + the awkward string, canonicalized by TS and by jq -cS,
    // must be byte-identical. Includes DEL (U+007F), the one code point where
    // JSON.stringify and jq diverge.
    const sample = {
      z_last: "zebra",
      a_first: 1,
      raw_response: 'line\n"q"\ttab\\back\ncafé ☕ 𝄞\x7fDEL\n\n',
      nested: { b: true, a: null },
      arr: [3, "x", false],
      exit_code: 0,
      neg: -5,
    };
    const tsCanon = canonicalStringify(sample as never);
    const jqCanon = execFileSync("jq", ["-cS", "."], {
      input: JSON.stringify(sample),
      encoding: "utf8",
    }).replace(/\n$/, "");
    c.check(tsCanon === jqCanon, "canonical: TS canonicalStringify byte-matches jq -cS (incl. U+007F)");

    // entry_hash reproduced exactly the way bash computes it (sha over canonical form).
    const { line, entryHash } = buildEntryLine({ b: "x", a: "y" });
    const jqSorted = execFileSync("jq", ["-cjS", "."], {
      input: JSON.stringify({ b: "x", a: "y" }),
      encoding: "utf8",
    });
    const expectHash = execFileSync("bash", ["-c", `printf %s ${shellQuote(jqSorted)} | sha256sum | cut -d" " -f1`], {
      encoding: "utf8",
    }).trim();
    c.check(entryHash === expectHash, "canonical: entry_hash == sha256 of jq -cjS canonical form");
    c.check(line.endsWith(`"entry_hash":"${entryHash}"}`), "canonical: entry_hash is appended LAST (bash quirk)");
  }

  // -------------------------------------------------------------------------
  // 1. A run with every entry type: lifecycle + final + disposition +
  //    subagent-voice + a delegate-diff with a real patch artifact, verified.
  // -------------------------------------------------------------------------
  let tsRunDir = "";
  let tsRunId = "";
  let tsLogDir = "";
  {
    tsLogDir = tmp();
    const env = envFor(tsLogDir, { COLLAB_LOG_PROMPTS: "full" });
    const log = new EvidenceLog({ env });
    tsRunId = log.newRun("/collab:delegate");
    const runEnv = envFor(tsLogDir, { COLLAB_RUN_ID: tsRunId, COLLAB_LOG_PROMPTS: "full" });
    const l = new EvidenceLog({ env: runEnv });
    await l.expect({ callId: "c1", command: "/collab:delegate", model: "openai/gpt-5", agent: "collab-build" });
    const st = await l.started({ callId: "c1", command: "/collab:delegate", model: "openai/gpt-5", agent: "collab-build", prompt: "do the work\n" });
    await l.completed({
      callId: "c1", exit: 0, turn: st.turn, command: "/collab:delegate", model: "openai/gpt-5", agent: "collab-build",
      captureState: "complete", response: 'model reply "q" \\b\ntrailing\x7f\n\n',
    });
    await l.final("summary the developer read");
    await l.disposition({ model: "openai/gpt-5", point: "the point", verdict: "Adapt", why: "partial" });
    await l.subagentVoice({ model: "claude-opus-4-8", label: "anthropic voice", response: 'subagent said\n"x"\n' });
    tsRunDir = l.dir(tsRunId);
    const patch = path.join(tsRunDir, "diff-c1.patch");
    writeFileSync(patch, "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1,2 @@\n orig\n+MODEL-EDIT\n");
    const dr = await l.diff({ callId: "c1", patchFile: patch, base: "basetree", after: "aftertree" });
    c.check(dr.ok, "diff: delegate-diff entry written");

    const tsv = l.verify(tsRunId);
    c.check(tsv.ok && tsv.code === 0, "verify: TS verifies its own full run (all 7 entry types)");
  }

  // -------------------------------------------------------------------------
  // 1c. Negative: corrupt one byte of a TS-written run → verify FAILS (code 7).
  // -------------------------------------------------------------------------
  {
    const env = envFor(tsLogDir, { COLLAB_LOG_PROMPTS: "full" });
    const file = path.join(tsRunDir, "calls.jsonl");
    const orig = readFileSync(file, "utf8");
    const arr = orig.split("\n");
    // Edit the completed (line 3) raw_response — a middle entry, breaks the chain.
    arr[2] = arr[2].replace("model reply", "MODEL LIED");
    writeFileSync(file, arr.join("\n"));
    const v = new EvidenceLog({ env }).verify(tsRunId);
    c.check(!v.ok && v.code === 7, "1c: a corrupted middle entry FAILS verify (code 7)");
    writeFileSync(file, orig); // restore
  }

  // -------------------------------------------------------------------------
  // 2b. LONE-SURROGATE (reviewer probe): a completed response carrying a lone \ud800
  //     must FAIL verify. JS JSON.parse ACCEPTS the escape while jq rejects it, so
  //     without the round-trip cleanliness check the verifier would pass an invalid log —
  //     a false-clean in the exact direction this project kills.
  // -------------------------------------------------------------------------
  {
    const dir = tmp();
    const env = envFor(dir, { COLLAB_RUN_ID: "surr" });
    const log = new EvidenceLog({ env });
    await log.expect({ callId: "s", model: "m/x", agent: "collab-read" });
    const st = await log.started({ callId: "s", model: "m/x", agent: "collab-read", prompt: "p" });
    // A model reply carrying a lone high surrogate; JSON.stringify serializes it as the
    // escape `\ud800`, so the stored line is exactly the reviewer's probe input.
    await log.completed({ callId: "s", exit: 0, turn: st.turn, captureState: "complete", response: "before\ud800after" });
    const file = path.join(dir, "surr", "calls.jsonl");
    c.check(readFileSync(file, "utf8").includes("\\ud800"), "2b setup: the stored line carries a lone \\ud800 escape");
    const tsv = log.verify("surr");
    c.check(!tsv.ok && tsv.code === 7, "2b: verify FAILS a lone-surrogate response (code 7)");
  }

  // -------------------------------------------------------------------------
  // 4. C22/C23 — 3-entry lifecycle sharing one call_id.
  // -------------------------------------------------------------------------
  {
    const dir = tmp();
    const env = envFor(dir, { COLLAB_RUN_ID: "run-lc" });
    const log = new EvidenceLog({ env });
    await log.expect({ callId: "x", command: "/c", model: "m/x", agent: "collab-read" });
    const st = await log.started({ callId: "x", command: "/c", model: "m/x", agent: "collab-read", prompt: "p" });
    await log.completed({ callId: "x", exit: 0, turn: st.turn, captureState: "complete", response: "a" });
    const es = parsed(path.join(dir, "run-lc", "calls.jsonl"));
    const types = es.map((e) => `${e.type}/${e.status}`);
    const ids = new Set(es.map((e) => e.call_id));
    c.check(
      es.length === 3 &&
        types.includes("expected-call/expected") &&
        types.includes("call/started") &&
        types.includes("call/completed") &&
        ids.size === 1 && ids.has("x"),
      "C22/C23: one call = expected+started+completed, all sharing one call_id",
    );
  }

  // -------------------------------------------------------------------------
  // 5. C24 — cardinality both directions: orphan started, orphan completed,
  //    duplicate started, duplicate completed all FAIL.
  // -------------------------------------------------------------------------
  {
    // orphan started (no completed)
    let dir = tmp();
    let env = envFor(dir, { COLLAB_RUN_ID: "r" });
    let log = new EvidenceLog({ env });
    await log.expect({ callId: "o", model: "m/x", agent: "collab-read" });
    await log.started({ callId: "o", model: "m/x", agent: "collab-read", prompt: "p" });
    c.check(log.verify("r").code === 7, "C24: an unpaired started FAILS verify");

    // orphan completed (no started) — the lost-prompt gap in disguise
    dir = tmp(); env = envFor(dir, { COLLAB_RUN_ID: "r" }); log = new EvidenceLog({ env });
    await log.expect({ callId: "o", model: "m/x", agent: "collab-read" });
    await log.completed({ callId: "o", exit: 0, captureState: "complete", response: "a" });
    c.check(log.verify("r").code === 7, "C24: an unpaired completed FAILS verify (both directions)");

    // duplicate started
    dir = tmp(); env = envFor(dir, { COLLAB_RUN_ID: "r" }); log = new EvidenceLog({ env });
    await log.expect({ callId: "d", model: "m/x", agent: "collab-read" });
    const st = await log.started({ callId: "d", model: "m/x", agent: "collab-read", prompt: "p" });
    await log.started({ callId: "d", model: "m/x", agent: "collab-read", prompt: "p" });
    await log.completed({ callId: "d", exit: 0, turn: st.turn, captureState: "complete", response: "a" });
    c.check(log.verify("r").code === 7, "C24: duplicate started FAILS exact cardinality");

    // duplicate completed
    dir = tmp(); env = envFor(dir, { COLLAB_RUN_ID: "r" }); log = new EvidenceLog({ env });
    await log.expect({ callId: "d", model: "m/x", agent: "collab-read" });
    const st2 = await log.started({ callId: "d", model: "m/x", agent: "collab-read", prompt: "p" });
    await log.completed({ callId: "d", exit: 0, turn: st2.turn, captureState: "complete", response: "a" });
    await log.completed({ callId: "d", exit: 0, turn: st2.turn, captureState: "complete", response: "a" });
    c.check(log.verify("r").code === 7, "C24: duplicate completed FAILS exact cardinality");
  }

  // -------------------------------------------------------------------------
  // 6. C25 — byte-exact raw_response (trailing newlines + DEL) and present-empty
  //    vs missing (carried decision).
  // -------------------------------------------------------------------------
  {
    const dir = tmp();
    const env = envFor(dir, { COLLAB_RUN_ID: "r" });
    const log = new EvidenceLog({ env });
    const awkward = "trailing bytes\n\n";
    await log.expect({ callId: "b", model: "m/x", agent: "collab-read" });
    const st = await log.started({ callId: "b", model: "m/x", agent: "collab-read", prompt: "p" });
    await log.completed({ callId: "b", exit: 0, turn: st.turn, captureState: "complete", response: awkward });
    const es = parsed(path.join(dir, "r", "calls.jsonl"));
    const comp = es.find((e) => e.status === "completed")!;
    c.check(comp.raw_response === awkward, "C25: raw_response keeps trailing newlines byte-exact");
    c.check(log.verify("r").ok, "C25: verify agrees with the byte-exact writer");

    // present-empty: complete + response "" stays complete with sha of "".
    const dir2 = tmp();
    const env2 = envFor(dir2, { COLLAB_RUN_ID: "r" });
    const log2 = new EvidenceLog({ env: env2 });
    await log2.expect({ callId: "e", model: "m/x", agent: "collab-read" });
    const st2 = await log2.started({ callId: "e", model: "m/x", agent: "collab-read", prompt: "p" });
    await log2.completed({ callId: "e", exit: 0, turn: st2.turn, captureState: "complete", response: "" });
    const compE = parsed(path.join(dir2, "r", "calls.jsonl")).find((e) => e.status === "completed")!;
    c.check(
      compE.capture_state === "complete" && compE.raw_response === "" &&
        compE.response_hash === "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "C25 (carried): present-but-empty response stays complete (sha of empty)",
    );

    // missing: complete + no response ⇒ downgrade to failed, and verify FAILS clean.
    const dir3 = tmp();
    const env3 = envFor(dir3, { COLLAB_RUN_ID: "r" });
    const log3 = new EvidenceLog({ env: env3 });
    await log3.expect({ callId: "m", model: "m/x", agent: "collab-read" });
    const st3 = await log3.started({ callId: "m", model: "m/x", agent: "collab-read", prompt: "p" });
    await log3.completed({ callId: "m", exit: 0, turn: st3.turn, captureState: "complete" }); // no response
    const compM = parsed(path.join(dir3, "r", "calls.jsonl")).find((e) => e.status === "completed")!;
    c.check(
      compM.capture_state === "failed" && compM.response_hash === null && log3.verify("r").code === 7,
      "C25 (carried): missing response downgrades complete→failed and cannot verify clean",
    );

    // A non-zero exit still writes completed and stays integral.
    const dir4 = tmp();
    const env4 = envFor(dir4, { COLLAB_RUN_ID: "r" });
    const log4 = new EvidenceLog({ env: env4 });
    await log4.expect({ callId: "z", model: "m/x", agent: "collab-read" });
    const st4 = await log4.started({ callId: "z", model: "m/x", agent: "collab-read", prompt: "p" });
    await log4.completed({ callId: "z", exit: 3, turn: st4.turn, captureState: "complete", response: "boom" });
    const compZ = parsed(path.join(dir4, "r", "calls.jsonl")).find((e) => e.status === "completed")!;
    c.check(compZ.exit_code === 3 && log4.verify("r").ok, "C25: a non-zero exit still writes an integral completed");
  }

  // -------------------------------------------------------------------------
  // 7. C25 (carried) — aborted send BEFORE started leaves only expected-call: the
  //    gap is preserved and made visible (verify fails), never auto-closed.
  // -------------------------------------------------------------------------
  {
    const dir = tmp();
    const env = envFor(dir, { COLLAB_RUN_ID: "r" });
    const log = new EvidenceLog({ env });
    await log.expect({ callId: "aborted", model: "m/x", agent: "collab-read" });
    // (An abort that produced a session DELETE but never reached `started` records NO
    //  completed — the durable expected-call is what surfaces the gap.)
    c.check(log.verify("r").code === 7, "C25 (carried): an expected-call with no lifecycle is a visible gap (verify fails)");
  }

  // -------------------------------------------------------------------------
  // 8. C26 — prompt privacy modes full / hash / off (off = no text AND no digest).
  // -------------------------------------------------------------------------
  {
    for (const mode of ["full", "hash", "off"] as PromptMode[]) {
      const dir = tmp();
      const env = envFor(dir, { COLLAB_RUN_ID: "r", COLLAB_LOG_PROMPTS: mode });
      const log = new EvidenceLog({ env });
      await log.expect({ callId: "p", model: "m/x", agent: "collab-read" });
      const st = await log.started({ callId: "p", model: "m/x", agent: "collab-read", prompt: "SENTINEL-abc123" });
      await log.completed({ callId: "p", exit: 0, turn: st.turn, captureState: "complete", response: "a" });
      const started = parsed(path.join(dir, "r", "calls.jsonl")).find((e) => e.status === "started")!;
      const hasText = started.prompt === "SENTINEL-abc123";
      const hasHash = typeof started.prompt_hash === "string";
      if (mode === "full") c.check(hasText && hasHash, "C26: full records prompt text + digest");
      if (mode === "hash") c.check(!hasText && hasHash, "C26: hash records digest only, not text");
      if (mode === "off") c.check(started.prompt === null && started.prompt_hash === null, "C26: off records NEITHER text nor digest");
      c.check(log.verify("r").ok, `C26: verify passes ${mode} mode`);
    }
  }

  // -------------------------------------------------------------------------
  // 9. C27 — chain + self-hash: editing a MIDDLE entry breaks the chain; editing
  //    the LAST entry is caught by the entry_hash self-check (tail blind spot).
  // -------------------------------------------------------------------------
  {
    const dir = tmp();
    const env = envFor(dir, { COLLAB_RUN_ID: "r" });
    const log = new EvidenceLog({ env });
    await log.expect({ callId: "a", model: "m/x", agent: "collab-read" });
    const s1 = await log.started({ callId: "a", model: "m/x", agent: "collab-read", prompt: "p" });
    await log.completed({ callId: "a", exit: 0, turn: s1.turn, captureState: "complete", response: "canned answer" });
    const file = path.join(dir, "r", "calls.jsonl");

    // middle edit (line 2 = started)
    let arr = readFileSync(file, "utf8").split("\n");
    const mid = arr[1].replace(/"prompt":"p"/, '"prompt":"HACKED"');
    c.check(mid !== arr[1], "C27 setup: middle line mutated");
    const saved = arr[1]; arr[1] = mid; writeFileSync(file, arr.join("\n"));
    c.check(log.verify("r").code === 7, "C27: editing a middle entry FAILS (prev_hash chain)");
    arr[1] = saved; writeFileSync(file, arr.join("\n"));
    c.check(log.verify("r").ok, "C27: restore verifies clean");

    // last-line edit — the chain has no successor; only entry_hash covers it.
    arr = readFileSync(file, "utf8").split("\n");
    arr[2] = arr[2].replace("canned answer", "SOMETHING ELSE");
    writeFileSync(file, arr.join("\n"));
    c.check(log.verify("r").code === 7, "C27: editing the LAST entry FAILS (entry_hash self-check covers the tail)");
  }

  // -------------------------------------------------------------------------
  // 10. C29 — disposition claim:true + verdict vocabulary; final; subagent-voice
  //     claim:true/captured:false/claimed_response; delegate-diff claim:false.
  // -------------------------------------------------------------------------
  {
    const dir = tmp();
    const env = envFor(dir, { COLLAB_RUN_ID: "r" });
    const log = new EvidenceLog({ env });
    await log.expect({ callId: "c1", model: "m/x", agent: "collab-read" });
    const st = await log.started({ callId: "c1", model: "m/x", agent: "collab-read", prompt: "p" });
    await log.completed({ callId: "c1", exit: 0, turn: st.turn, captureState: "complete", response: "a" });

    const good = await log.disposition({ model: "m/x", point: "p", verdict: "Adopt" });
    const bad = await log.disposition({ model: "m/x", point: "p", verdict: "Maybe" as never });
    c.check(good.ok && !bad.ok, "C29: disposition accepts Adopt, rejects a bogus verdict (no throw)");
    const disp = parsed(path.join(dir, "r", "calls.jsonl")).find((e) => e.type === "claude-disposition")!;
    c.check(disp.claim === true, "C29: disposition is claim:true");

    const svResp = 'subagent says:\n  "quote", back\\slash\n';
    await log.subagentVoice({ model: "claude-opus-4-8", label: "voice", response: svResp });
    const sv = parsed(path.join(dir, "r", "calls.jsonl")).find((e) => e.type === "subagent-voice")!;
    c.check(
      sv.claim === true && sv.captured === false && sv.transport === "claude-subagent" &&
        !("raw_response" in sv) && sv.claimed_response === svResp,
      "C29: subagent-voice is claim:true/captured:false, uses claimed_response not raw_response, byte-exact",
    );
    c.check(log.verify("r").ok, "C29: verify accepts opencode call + disposition + subagent-voice");

    // Tamper the final subagent-voice text (the last line) → response_hash self-check
    // catches it, since the chain has no successor to cover the tail.
    const file = path.join(dir, "r", "calls.jsonl");
    const arr = readFileSync(file, "utf8").split("\n");
    const idx = arr.map((l, i) => (l.length ? i : -1)).filter((i) => i >= 0).pop()!;
    arr[idx] = arr[idx].replace("subagent says", "subagent LIED");
    writeFileSync(file, arr.join("\n"));
    c.check(log.verify("r").code === 7, "C29: an altered subagent-voice transcript FAILS (response_hash)");
  }

  // -------------------------------------------------------------------------
  // 11. C28/C29 — delegate-diff patch hashed; missing patch and tampered patch FAIL.
  // -------------------------------------------------------------------------
  {
    const dir = tmp();
    const env = envFor(dir, { COLLAB_RUN_ID: "r" });
    const log = new EvidenceLog({ env });
    await log.expect({ callId: "d1", model: "m/x", agent: "collab-build" });
    const st = await log.started({ callId: "d1", model: "m/x", agent: "collab-build", prompt: "p" });
    await log.completed({ callId: "d1", exit: 0, turn: st.turn, captureState: "complete", response: "did work" });
    const rd = log.dir("r");
    const patch = path.join(rd, "diff-d1.patch");
    writeFileSync(patch, "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-o\n+n\ndiff --git a/y b/y\n--- a/y\n+++ b/y\n@@ -1 +1 @@\n-a\n+b\n");
    const dr = await log.diff({ callId: "d1", patchFile: patch, base: "bt", after: "at" });
    const diffEntry = parsed(path.join(rd, "calls.jsonl")).find((e) => e.type === "delegate-diff")!;
    c.check(dr.ok && diffEntry.claim === false && diffEntry.files_changed === 2, "C29: delegate-diff is claim:false, counts 2 changed files");
    c.check(log.verify("r").ok, "C28: verify passes with a present, hash-matching patch");

    // tamper the patch → verify FAILS
    writeFileSync(patch, readFileSync(patch, "utf8") + "tampered\n");
    c.check(log.verify("r").code === 7, "C28: a tampered patch FAILS verify (diff is inside the integrity contract)");

    // missing patch → verify FAILS
    rmSync(patch);
    c.check(log.verify("r").code === 7, "C28: a MISSING referenced patch FAILS verify");

    // diff with a nonexistent patch file is a no-op that does not throw
    const nope = await log.diff({ callId: "d1", patchFile: path.join(rd, "does-not-exist.patch") });
    c.check(!nope.ok, "C28: diff() on a missing patch file returns ok:false, does not throw");
  }

  // -------------------------------------------------------------------------
  // 12. C30 — a subagent-voice-only run verifies (all-Anthropic collab); a
  //     claude-final-only run does NOT.
  // -------------------------------------------------------------------------
  {
    const dir = tmp();
    const env = envFor(dir, { COLLAB_RUN_ID: "sv" });
    const log = new EvidenceLog({ env });
    await log.subagentVoice({ model: "claude-opus-4-8", response: "lone subagent reply" });
    c.check(log.verify("sv").ok, "C30: a subagent-voice-only run verifies (all-Anthropic collab is not empty)");

    const dir2 = tmp();
    const env2 = envFor(dir2, { COLLAB_RUN_ID: "cf" });
    const log2 = new EvidenceLog({ env: env2 });
    await log2.final("only a summary, no model call");
    c.check(log2.verify("cf").code === 7, "C30: a claude-final-only run FAILS (no lifecycle nor voice)");
  }

  // -------------------------------------------------------------------------
  // 13. C31 — logging never throws into the caller (unwritable log dir).
  // -------------------------------------------------------------------------
  {
    // Point the log dir at a path whose parent is a FILE, so mkdir/append fail.
    const base = tmp();
    const blocker = path.join(base, "blocker");
    writeFileSync(blocker, "not a dir");
    const env = envFor(path.join(blocker, "logs"), { COLLAB_RUN_ID: "r" });
    const log = new EvidenceLog({ env });
    let threw = false;
    let res;
    try {
      res = await log.started({ callId: "x", model: "m/x", agent: "collab-read", prompt: "p" });
    } catch {
      threw = true;
    }
    c.check(!threw && res !== undefined && res.ok === false, "C31: an unwritable log dir returns ok:false, never throws");
  }

  // -------------------------------------------------------------------------
  // 13b. C31 (audit path) — verify() must not THROW on an IO error (an MCP handler
  //      calls it). A calls.jsonl that is a DIRECTORY makes readFileSync throw EISDIR;
  //      verify must catch it and return a failed result, not propagate.
  // -------------------------------------------------------------------------
  {
    const dir = tmp();
    const env = envFor(dir, { COLLAB_RUN_ID: "iofail" });
    // Put a DIRECTORY where calls.jsonl should be, so existsSync passes but read fails.
    mkdirSync(path.join(dir, "iofail", "calls.jsonl"), { recursive: true });
    const log = new EvidenceLog({ env });
    let threw = false;
    let v;
    try {
      v = log.verify("iofail");
    } catch {
      threw = true;
    }
    c.check(!threw && v !== undefined && !v.ok && v.code === 7, "C31: verify() on an unreadable log returns a failed result (code 7), never throws");
  }

  // -------------------------------------------------------------------------
  // 14. C32 — retention/prune removes old run dirs; only run-id-shaped dirs.
  // -------------------------------------------------------------------------
  {
    const dir = tmp();
    const env = envFor(dir);
    const log = new EvidenceLog({ env });
    const oldRun = path.join(dir, "20200101T000000Z-deadbeef");
    mkdirSync(oldRun, { recursive: true });
    const notARun = path.join(dir, "keepme");
    mkdirSync(notARun, { recursive: true });
    const old = new Date(Date.now() - 60 * 86_400_000);
    utimesSync(oldRun, old, old);
    utimesSync(notARun, old, old);
    log.prune(14);
    c.check(!existsSync(oldRun), "C32: prune removes a 60-day-old run dir");
    c.check(existsSync(notARun), "C32: prune leaves a non-run-shaped dir untouched");
  }

  // -------------------------------------------------------------------------
  // 15. run-id format + fresh-id-even-when-COLLAB_RUN_ID-set + latest symlink.
  // -------------------------------------------------------------------------
  {
    const dir = tmp();
    const r1 = new EvidenceLog({ env: envFor(dir) }).newRun("/collab:consult");
    c.check(/^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$/.test(r1), "run-id: matches YYYYMMDDTHHMMSSZ-<8hex>");
    // new-run mints fresh even with an ambient COLLAB_RUN_ID.
    const r2 = new EvidenceLog({ env: envFor(dir, { COLLAB_RUN_ID: r1 }) }).newRun("/collab:panel");
    c.check(r2 !== "" && r2 !== r1, "newRun: mints a fresh id even when COLLAB_RUN_ID is set");
    // latest points at the most recent run.
    c.check(new EvidenceLog({ env: envFor(dir) }).latest() === r2, "latest: resolves the most recent run id");
  }

  // -------------------------------------------------------------------------
  // 16. C33 — partitioning: same-basename projects distinguished by path-hash suffix;
  //     OFF ⇒ flat; explicit COLLAB_LOG_DIR disables partitioning.
  // -------------------------------------------------------------------------
  {
    const base = tmp();
    const collabDir = path.join(base, "collab");
    mkdirSync(collabDir, { recursive: true });
    const baseLogs = path.join(collabDir, "logs");
    // Two same-basename project roots under different parents.
    const sharedA = path.join(tmp(), "proj");
    const sharedB = path.join(tmp(), "proj");
    mkdirSync(sharedA, { recursive: true });
    mkdirSync(sharedB, { recursive: true });
    gitInit(sharedA); gitInit(sharedB);
    const mk = (cwd: string) =>
      new EvidenceLog({ env: envForNoLogDir({ COLLAB_LOG_PARTITION: "1" }), cwd, collabDir });
    const rA = mk(sharedA).newRun("/collab:consult");
    const dirA = mk(sharedA).dir(rA);
    const rB = mk(sharedB).newRun("/collab:consult");
    const dirB = mk(sharedB).dir(rB);
    const keyA = dirA.slice(baseLogs.length + 1).split("/")[0];
    const keyB = dirB.slice(baseLogs.length + 1).split("/")[0];
    c.check(
      dirA.startsWith(baseLogs + "/") && keyA !== rA && dirA === path.join(baseLogs, keyA, rA),
      "C33: PARTITION=1 places a run under <base>/<project-key>/<run>",
    );
    c.check(
      keyA !== keyB && keyA.startsWith("proj-") && keyB.startsWith("proj-"),
      "C33: same-basename projects get DISTINCT keys via the path-hash suffix",
    );
    // OFF ⇒ flat under base.
    const off = new EvidenceLog({ env: envForNoLogDir(), cwd: sharedA, collabDir });
    const rOff = off.newRun("/collab:consult");
    c.check(off.dir(rOff) === path.join(baseLogs, rOff), "C33: partitioning OFF ⇒ run lands directly in base logs dir");
    // explicit COLLAB_LOG_DIR beats PARTITION=1.
    const explicit = tmp();
    const ex = new EvidenceLog({ env: envFor(explicit, { COLLAB_LOG_PARTITION: "1" }), cwd: sharedA, collabDir });
    const rE = ex.newRun("/collab:consult");
    c.check(ex.dir(rE) === path.join(explicit, rE), "C33: explicit COLLAB_LOG_DIR disables partitioning");
  }

  // -------------------------------------------------------------------------
  // 17. C35 — config resolution env > collab.conf.local > default (confGet + live).
  // -------------------------------------------------------------------------
  {
    // confGet parsing (the parser the whole config layer shares).
    const conf = [
      "# comment",
      "  COLLAB_LOG_PROMPTS = hash   # inline comment",
      'COLLAB_MODEL="openai/gpt-5"',
      "COLLAB_MODEL='second-wins'",
      "no_equals_line",
    ].join("\n");
    c.check(confGet(conf, "COLLAB_LOG_PROMPTS") === "hash", "C35: confGet strips whitespace + inline comment");
    c.check(confGet(conf, "COLLAB_MODEL") === "second-wins", "C35: confGet — last assignment wins, quotes stripped");
    c.check(confGet(conf, "ABSENT") === "", "C35: confGet returns empty for an absent key");

    // Live: a config file sets COLLAB_LOG_PROMPTS=off; a started entry records no prompt.
    const base = tmp();
    const collabDir = path.join(base, "collab");
    mkdirSync(collabDir, { recursive: true });
    writeFileSync(path.join(collabDir, "collab.conf.local"), "COLLAB_LOG_PROMPTS=off\n");
    const logDir = path.join(collabDir, "logs");
    const log = new EvidenceLog({ env: { ...cleanEnv(), COLLAB_LOG_DIR: logDir, COLLAB_RUN_ID: "r" } as NodeJS.ProcessEnv, collabDir });
    await log.expect({ callId: "p", model: "m/x", agent: "collab-read" });
    const st = await log.started({ callId: "p", model: "m/x", agent: "collab-read", prompt: "SENTINEL-abc123" });
    const started = parsed(path.join(logDir, "r", "calls.jsonl")).find((e) => e.status === "started")!;
    c.check(started.prompt === null && started.prompt_hash === null, "C35: COLLAB_LOG_PROMPTS honored from collab.conf.local");
    // env overrides the file.
    const log2 = new EvidenceLog({ env: { ...cleanEnv(), COLLAB_LOG_DIR: logDir, COLLAB_RUN_ID: "r2", COLLAB_LOG_PROMPTS: "full" } as NodeJS.ProcessEnv, collabDir });
    await log2.expect({ callId: "p", model: "m/x", agent: "collab-read" });
    await log2.started({ callId: "p", model: "m/x", agent: "collab-read", prompt: "SENTINEL-abc123" });
    void st;
    const started2 = parsed(path.join(logDir, "r2", "calls.jsonl")).find((e) => e.status === "started")!;
    c.check(started2.prompt === "SENTINEL-abc123", "C35: env COLLAB_LOG_PROMPTS overrides the config file");
  }

  // -------------------------------------------------------------------------
  // 18. C34 — three GENUINELY-CONCURRENT writer processes get distinct turns, 9 intact
  //     JSONL lines, and the run verifies. Proves the mkdir lock under real contention.
  //
  //     Spawned via async `spawn` (NOT spawnSync-in-a-Promise, which blocks the event
  //     loop and runs children in series — a lock is never contended, so the test would
  //     pass with no lock at all). Each child holds between its appends and prints its
  //     wall-clock span; the test ASSERTS OVERLAP (all three alive at one instant), which
  //     is impossible under serialization. This is the "guarantee holds only where
  //     tested" trap the repo memory names, closed.
  // -------------------------------------------------------------------------
  {
    const dir = tmp();
    const runId = new EvidenceLog({ env: envFor(dir) }).newRun("/collab:panel");
    const hold = "150";
    const results = await Promise.all(
      ["k1", "k2", "k3"].map((cid) =>
        spawnAsync(tsxBin, [CHILD], envFor(dir, { COLLAB_RUN_ID: runId, CHILD_CALL_ID: cid, COLLAB_TEST_HOLD_MS: hold })),
      ),
    );
    const file = path.join(dir, runId, "calls.jsonl");
    const es = parsed(file);
    const turns = new Set(es.filter((e) => e.status === "started").map((e) => e.turn));
    const spans = results.map((r) => parseSpan(r.stdout)).filter((s): s is { start: number; end: number } => !!s);
    // Genuine overlap: the LATEST start precedes the EARLIEST end ⇒ at some instant all
    // three children were alive at once. Under serialization each start ≥ the prior end,
    // so latestStart ≥ earliestEnd and this fails.
    const latestStart = Math.max(...spans.map((s) => s.start));
    const earliestEnd = Math.min(...spans.map((s) => s.end));
    const overlapped = spans.length === 3 && latestStart < earliestEnd;

    c.check(results.every((r) => r.status === 0), "C34: all 3 concurrent writer processes exited 0");
    c.check(overlapped, `C34: the 3 writers genuinely OVERLAP (latestStart ${latestStart} < earliestEnd ${earliestEnd})`);
    c.check(es.length === 9, "C34: 3 concurrent lifecycles ⇒ 9 intact JSONL lines (no torn appends)");
    c.check(turns.size === 3, "C34: concurrent started entries get 3 DISTINCT turns (turn counted inside the lock)");
    c.check(new EvidenceLog({ env: envFor(dir) }).verify(runId).ok, "C34: the concurrent run verifies");
    console.log(`    [overlap evidence] spans: ${spans.map((s) => `${s.start % 100000}..${s.end % 100000}`).join(", ")} → latestStart ${latestStart % 100000} < earliestEnd ${earliestEnd % 100000}`);
  }

  // cleanup
  for (const d of tmpDirs) {
    try { rmSync(d, { recursive: true, force: true }); } catch { /* ignore */ }
  }

  console.log(`log.test: ${c.passes} passed, ${c.failures} failed`);
  return c.failures;
}

// --- local helpers ----------------------------------------------------------
/** An env with COLLAB_* knobs cleared, so a test's expectations aren't perturbed by
 * the developer's shell (e.g. a real COLLAB_LOG_DIR). */
function cleanEnv(): NodeJS.ProcessEnv {
  const e = { ...process.env };
  for (const k of Object.keys(e)) if (k.startsWith("COLLAB_")) delete e[k];
  return e;
}
function envForNoLogDir(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  return { ...cleanEnv(), ...extra } as NodeJS.ProcessEnv;
}
function gitInit(dir: string): void {
  spawnSync("git", ["init", "-q"], { cwd: dir });
}

/** Spawn a child ASYNCHRONOUSLY (unlike spawnSync, which blocks the event loop and would
 * force children to run in series — defeating any concurrency test). Resolves with the
 * exit status and captured stdout only after the child exits, so `Promise.all` over
 * several of these runs them genuinely simultaneously. */
function spawnAsync(
  cmd: string,
  args: string[],
  env: NodeJS.ProcessEnv,
): Promise<{ status: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { env });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("close", (code) => resolve({ status: code ?? -1, stdout, stderr }));
    child.on("error", () => resolve({ status: -1, stdout, stderr }));
  });
}

/** Parse `START <ms> END <ms>` overlap markers a child (or shell) prints. */
function parseSpan(s: string): { start: number; end: number } | undefined {
  const m = s.match(/START (\d+) END (\d+)/);
  return m ? { start: Number(m[1]), end: Number(m[2]) } : undefined;
}
function shellQuote(s: string): string {
  return "'" + s.replace(/'/g, "'\\''") + "'";
}

if (import.meta.url === `file://${process.argv[1]}`) {
  run().then((f) => process.exit(f > 0 ? 1 : 0));
}
