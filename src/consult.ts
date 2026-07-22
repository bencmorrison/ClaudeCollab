/**
 * collab_consult — the first PRODUCTION tool (PLAN.md M5).
 *
 * Composes the four committed layers into the read-only "second opinion" flow the bash
 * `/collab:consult` gives, translated to the MCP surface:
 *
 *   config root (resolved ONCE, multi-root conflict surfaced)  ── config.ts
 *     → model resolution + leading-dash refusal (C12)          ── config.ts
 *     → policy gate deny/ask/allow (C1–C7)                     ── policy.ts
 *     → evidence lifecycle expect→started→completed (C22–C25)  ── log.ts
 *     → the model turn via the UNMODIFIED collab-read agent    ── client.ts
 *
 * The bash exit codes (CONTRACT.md area H) become STRUCTURED tool errors, not process
 * exits: a denied model is exit 3 → a `policy-deny` error naming the model and tier; an
 * `ask`-tier model without `confirmed:true` is exit 4 → a `policy-ask` error whose text
 * instructs the DRIVER to ask the human and retry with `confirmed:true`. That is C41's
 * two-layer defense on the MCP side: Claude cannot self-confirm silently because the
 * mechanical gate lives here (the tool), and the error text says the USER must be asked.
 *
 * EVIDENCE-GAP PARITY (C24). Everything that can refuse the call — a leading-dash model
 * id, a policy deny, an unconfirmed ask — refuses BEFORE `expect` is written, so a
 * refused call logs NOTHING (matching ask.sh, which refuses before it logs). Once
 * `expect` is written, EVERY path (success, empty answer, thrown model call) ends in
 * exactly one `started` + one `completed`, so the log never carries a dangling
 * expected-call. A thrown model call records `completed` with `capture_state:failed` and
 * returns a `call-failed` error carrying the reason — NEVER a fabricated answer.
 *
 * Logging is best-effort and never fails the call it records (C31): the log layer's write
 * methods already return `{ok}` instead of throwing, and this flow ignores their `ok`.
 */

import { randomBytes } from "node:crypto";
import os from "node:os";
import { askViaAgent, AgentMismatchError, type ServeProvider } from "./client.js";
import { EvidenceLog } from "./log.js";
import {
  resolveCollabRoot,
  candidateRoots,
  readConfContents,
  resolveModel,
  checkResolvedModelId,
  type CollabRoot,
  type RootSource,
} from "./config.js";
import { policyTier, resolvePolicyFile, type PolicyTier, type PolicySource } from "./policy.js";

/** The read-only agent this tool ALWAYS uses, unmodified (C15/C47/C48). */
export const CONSULT_AGENT = "collab-read";
/** The command label recorded in the evidence log (drives `/collab:witness`). */
export const CONSULT_COMMAND = "/collab:consult";

// --- Root resolution + conflict surfacing (M4 "doctor MUST warn") ----------
export interface RootResolution {
  root: string;
  source: RootSource;
  /** Every root that exists on disk, precedence order (env > project > home). */
  candidates: CollabRoot[];
  /** Set iff >1 root exists on disk: which won, which are shadowed, how to fix. */
  conflict?: string;
}

/**
 * Resolve the collab root ONCE and, if more than one root exists on disk, describe the
 * conflict so the caller (consult metadata + collab_status) can surface it. The chosen
 * root is `resolveCollabRoot`'s (env > project > home); when >1 candidate exists the
 * winner is `candidates[0]` and equals the chosen root.
 */
export function resolveRootWithConflict(
  env: NodeJS.ProcessEnv = process.env,
  cwd: string = process.cwd(),
  home: string = os.homedir(),
): RootResolution {
  const chosen = resolveCollabRoot(env, cwd, home);
  const candidates = candidateRoots(env, cwd, home);
  const override = env.COLLAB_ROOT;
  const hasOverride = override !== undefined && override.length > 0;
  let conflict: string | undefined;
  // An explicit $COLLAB_ROOT is a deliberate disambiguation — the winner is unambiguous
  // and no root is *silently* shadowed, so it is NOT a conflict. The warning exists for
  // the fail-open case where a policy in one root silently doesn't bind because a
  // different root won WITHOUT the user having chosen (project vs home), so only report
  // it when there was no override AND more than one root exists on disk.
  if (!hasOverride && candidates.length > 1) {
    const winner = candidates[0];
    const shadowed = candidates.slice(1).map((r) => `${r.source} (${r.root})`);
    conflict =
      `multiple collab roots exist on disk — using ${winner.source} (${winner.root}); ` +
      `shadowed: ${shadowed.join(", ")}. ` +
      `The winning root's policy and config are the ones in effect; set $COLLAB_ROOT to choose deliberately.`;
  }
  return { root: chosen.root, source: chosen.source, candidates, conflict };
}

// --- Doctor-seed checks (M4 "doctor MUST warn"; surfaced by collab_status) --
export interface CollabDoctorSeed {
  /** Which collab root is in effect, and — if >1 exists on disk — the conflict note. */
  collabRoot: { root: string; source: RootSource; conflict: string | null };
  /** The model-policy file that would govern a call, and which slot supplied it. */
  policy: { file: string; source: PolicySource };
  /** Evidence layer on/off and the effective log directory. */
  logging: { enabled: boolean; logDir: string };
}

/**
 * The filesystem/env checks M4 made a precondition for production: multi-root conflict,
 * the active policy file + source, and logging on/off + effective dir. No serve needed.
 * Pure and injectable so `collab_status` and its test drive the SAME code.
 *
 * CALLER-BEWARE (deliberate, not a bug): an explicit `$COLLAB_ROOT` pointing at a root
 * that has NO policy file resolves to default-allow (C4) and reports NO conflict — the
 * override is trusted as the user's deliberate choice. So `policy.source` may read
 * `committed`/`local` for a file that does not exist there; every model is then allowed.
 * Surfaced here so the operator can see which root (and which policy file) is actually in
 * effect rather than assuming a policy binds when none is present.
 */
export function collabDoctorSeed(
  env: NodeJS.ProcessEnv = process.env,
  cwd: string = process.cwd(),
  home: string = os.homedir(),
): CollabDoctorSeed {
  const rootRes = resolveRootWithConflict(env, cwd, home);
  const collabDir = rootRes.root;
  const policy = resolvePolicyFile(collabDir, env);
  const log = new EvidenceLog({ env, cwd, collabDir });
  return {
    collabRoot: { root: rootRes.root, source: rootRes.source, conflict: rootRes.conflict ?? null },
    policy: { file: policy.file, source: policy.source },
    logging: { enabled: log.enabled(), logDir: log.logDir() },
  };
}

// --- Result / error shapes -------------------------------------------------
export type ConsultErrorKind =
  | "model-id"
  | "policy-deny"
  | "policy-ask"
  | "call-failed"
  | "agent-mismatch";

export interface ConsultAttribution {
  /** The EXACT model id used (consult.md reports the model id used — area-F command
   * surface; NOT C45, which is verify-not-relay): the resolved id, or the id opencode actually ran
   * (from the turn metadata) when the caller left it to opencode's default. */
  model: string;
  /** The id we resolved and asked for — `""` means "opencode's own default". */
  requestedModel: string;
  agent: string;
  runId: string;
  callId: string;
}

export interface ConsultError {
  kind: ConsultErrorKind;
  message: string;
  /**
   * The bash exit code this maps to: 2 model-id (C55), 3 deny (C56), 4 ask (C56). For a
   * `call-failed` this is **null**, NOT 0 — bash propagates opencode's own non-zero
   * status verbatim (C53) with no fixed collab code, and 0 is reserved for success
   * (C53), so a numeric code here would be a lie. `kind:"call-failed"` + `isError` is the
   * failure signal; the message carries the underlying reason.
   */
  exitAnalogue: number | null;
  /** The model id involved, for a machine-readable error envelope. */
  model: string;
  /** Present on policy errors: the tier that produced the refusal. */
  tier?: PolicyTier;
}

export interface ConsultOk {
  ok: true;
  answer: string;
  attribution: ConsultAttribution;
  /** Multi-root conflict note, if any (surfaced, never fatal). */
  rootConflict?: string;
  /**
   * The opencode session id, returned ONLY when `keepSession` was requested (a deleted
   * session's id is useless). This is the sole way a caller threads a follow-up turn:
   * pass it back as `sessionId`. There is deliberately NO parameter for handing back the
   * peer's previous ANSWER — continuation is by session id, never by re-transmitting the
   * other model's words (PLAN.md "Option B" guarantee).
   */
  sessionId?: string;
}
export interface ConsultFail {
  ok: false;
  error: ConsultError;
  /** Even on a refusal, tell the caller which root's policy did the refusing. */
  rootConflict?: string;
}
export type ConsultResult = ConsultOk | ConsultFail;

// --- Params + deps ---------------------------------------------------------
export interface ConsultParams {
  question: string;
  model?: string;
  runId?: string;
  confirmed?: boolean;
  /**
   * Continue an EXISTING opencode session (Option B). The peer's prior turns already
   * live in that session, so `question` is the only new text sent — the driver never
   * re-quotes the other model. This is the round-2 primitive for `/collab:workshop`
   * (each panel member continues its OWN round-1 session; see panel.ts keepSessions).
   */
  sessionId?: string;
  /** Keep the session alive after this turn and return its id (for a further turn). */
  keepSession?: boolean;
}

export interface ConsultDeps {
  /** A ready-serve provider (the M1 lifecycle in production; a fake in tests). */
  serve: ServeProvider;
  env?: NodeJS.ProcessEnv;
  cwd?: string;
  home?: string;
  /** Injected in tests so root/policy/log all share one collab dir; else resolved. */
  log?: EvidenceLog;
  /** Per-turn timeout override (tests shorten it). */
  messageTimeoutMs?: number;
}

/** A fresh, non-empty call id (the pairing key for a call's three lifecycle entries). */
function newCallId(): string {
  return `call-${randomBytes(8).toString("hex")}`;
}

/** The exact model id that ran: prefer the resolved request; if it was empty (opencode
 * default) fall back to the provider/model the turn metadata reports. */
function actualModel(requested: string, providerID?: string, modelID?: string): string {
  if (requested !== "") return requested;
  if (providerID && modelID) return `${providerID}/${modelID}`;
  return "(opencode default)";
}

// ===========================================================================
// SHARED FLOW (factored so collab_panel — M6 — reuses the exact same gating and
// lifecycle as collab_consult, rather than a divergent second copy). The gate is
// pure (no logging, no run); the lifecycle is the expect→started→completed spine.
// ===========================================================================

/** A refusal produced by `gateModel` BEFORE any log write. A model-id/deny/ask
 * refusal is identical whether it comes from consult or a panel member — the
 * caller maps it into its own error envelope. */
export interface GateRefusal {
  kind: "model-id" | "policy-deny" | "policy-ask";
  message: string;
  /** bash exit analogue: 2 model-id (C55), 3 deny, 4 ask (C56). */
  exitAnalogue: number;
  model: string;
  /** Present on policy refusals: the tier that refused. */
  tier?: PolicyTier;
}

export type GateOutcome =
  | { ok: true; tier: PolicyTier; confirmed: boolean }
  | { ok: false; refusal: GateRefusal };

/**
 * The pre-log gate shared by every model-touching call: the leading-dash model-id
 * refusal (C12) THEN the policy tier gate (C1–C7). Deterministic ordering — model-id
 * is checked first, so a dash-leading id that a `deny -*` rule would also match is
 * refused as `model-id`, not `policy-deny`. Pure: it writes NOTHING, so a refusal
 * logs nothing (C24 gap parity), exactly like ask.sh refusing before it logs.
 *
 * `confirmed` is the human-approval flag for an ask-tier model. It only unlocks an
 * ask-tier call; on allow/deny it is simply recorded (allow) or irrelevant (deny).
 */
export function gateModel(
  requestedModel: string,
  confirmed: boolean,
  deps: { collabDir: string; env: NodeJS.ProcessEnv },
): GateOutcome {
  const idCheck = checkResolvedModelId(requestedModel);
  if (!idCheck.ok) {
    return {
      ok: false,
      refusal: {
        kind: "model-id",
        message: idCheck.reason ?? `refusing model id '${requestedModel}'.`,
        exitAnalogue: idCheck.exitCode ?? 2,
        model: requestedModel,
      },
    };
  }
  const decision = policyTier(requestedModel, { collabDir: deps.collabDir, env: deps.env });
  const modelLabel = requestedModel === "" ? "(opencode default)" : requestedModel;
  if (decision.tier === "deny") {
    return {
      ok: false,
      refusal: {
        kind: "policy-deny",
        model: requestedModel,
        tier: "deny",
        exitAnalogue: 3,
        message:
          decision.reason ??
          `Model '${modelLabel}' is DENIED by the model policy (${decision.source} policy at ${decision.policyFile}). ` +
            `Not consulting it. Choose an allowed model or change the policy.`,
      },
    };
  }
  if (decision.tier === "ask" && confirmed !== true) {
    return {
      ok: false,
      refusal: {
        kind: "policy-ask",
        model: requestedModel,
        tier: "ask",
        exitAnalogue: 4,
        message:
          `Model '${modelLabel}' is gated ASK by the model policy (${decision.source} policy at ${decision.policyFile}). ` +
          `This tool will NOT consult it until the human user explicitly approves. ` +
          `Ask the user whether to consult '${modelLabel}', and only if they say yes, retry with confirmed:true. ` +
          `Do not set confirmed yourself — it represents the user's approval, not yours.`,
      },
    };
  }
  return { ok: true, tier: decision.tier, confirmed: confirmed === true };
}

export interface LifecycleParams {
  question: string;
  requestedModel: string;
  agent: string;
  command: string;
  /** Session title recorded by opencode (diagnostic only). */
  title: string;
  runId: string;
  tier: PolicyTier;
  confirmed: boolean;
  /**
   * SESSION CONTINUATION (M7 / Option B). Continue this EXISTING opencode session
   * (skip create); its id is known up front so it is recorded on the `started` entry
   * too, letting the witness see which turns shared a session. Omit to mint a fresh one.
   */
  sessionId?: string;
  /** Keep the session alive after the turn (return its id); default deletes it. */
  keepSession?: boolean;
}

export interface LifecycleDeps {
  serve: ServeProvider;
  log: EvidenceLog;
  messageTimeoutMs?: number;
}

export type LifecycleOutcome =
  | { ok: true; text: string; callId: string; actualModel: string; sessionId: string }
  | { ok: false; callId: string; reason: string; kind: "call-failed" | "agent-mismatch" };

/**
 * The evidence spine every model turn shares: mint a call id, write expect→started
 * BEFORE the call, run the model turn via the UNMODIFIED agent, then write completed
 * on EVERY path (success or thrown). A thrown call records `completed` with
 * `capture_state:failed` and NO fabricated answer, closing the expected-call gap
 * (C24/C25). Assumes the run is already resolved and the gate already passed — so it
 * always writes exactly one started + one completed for its call id.
 */
export async function runAgentLifecycle(
  p: LifecycleParams,
  d: LifecycleDeps,
): Promise<LifecycleOutcome> {
  const callId = newCallId();
  const common = {
    callId,
    command: p.command,
    model: p.requestedModel,
    agent: p.agent,
    tier: p.tier,
    confirmed: p.confirmed,
    run: p.runId,
  };
  await d.log.expect({
    callId,
    command: p.command,
    model: p.requestedModel,
    agent: p.agent,
    run: p.runId,
  });
  // On a continuation the session id is known before the call, so it is stamped on
  // `started` too (a fresh session is only known post-call and lands on `completed`).
  const started = await d.log.started({ ...common, session: p.sessionId, prompt: p.question });
  try {
    const result = await askViaAgent(d.serve, {
      agent: p.agent,
      model: p.requestedModel === "" ? undefined : p.requestedModel,
      prompt: p.question,
      title: p.title,
      messageTimeoutMs: d.messageTimeoutMs,
      sessionId: p.sessionId,
      keepSession: p.keepSession,
      // Fail closed if opencode serves a different agent than the hardened one requested.
      expectedAgent: p.agent,
    });
    await d.log.completed({
      ...common,
      exit: 0,
      turn: started.turn,
      session: result.sessionId,
      captureState: "complete",
      response: result.text,
    });
    return {
      ok: true,
      text: result.text,
      callId,
      actualModel: actualModel(p.requestedModel, result.metadata.providerID, result.metadata.modelID),
      sessionId: result.sessionId,
    };
  } catch (err) {
    const mismatch = err instanceof AgentMismatchError;
    const reason = err instanceof Error ? err.message : String(err);
    await d.log.completed({
      ...common,
      exit: 1,
      turn: started.turn,
      // Record the session id we know: the served one on a mismatch, else the continued
      // id (item 4 — a failed continuation must still record which session it was; null
      // for a fresh session whose id we never learned before the throw).
      session: mismatch ? err.sessionId : p.sessionId,
      captureState: "failed",
    });
    return { ok: false, callId, reason, kind: mismatch ? "agent-mismatch" : "call-failed" };
  }
}

/**
 * Run one consult. Pure of the MCP layer: returns a discriminated result the server
 * translates into an MCP tool result. Never throws for an expected refusal or a model
 * failure — both are `{ ok:false }` data. (A programming error in a dep could still
 * throw; the server wraps the call.)
 */
export async function consult(params: ConsultParams, deps: ConsultDeps): Promise<ConsultResult> {
  const env = deps.env ?? process.env;
  const cwd = deps.cwd ?? process.cwd();
  const home = deps.home ?? os.homedir();

  // 1. Resolve the config root ONCE; surface a multi-root conflict.
  const rootRes = resolveRootWithConflict(env, cwd, home);
  const collabDir = rootRes.root;
  const rootConflict = rootRes.conflict;

  // 2. Resolve the model (param > COLLAB_MODEL env > conf > opencode default).
  const confContents = readConfContents(collabDir, env);
  const requestedModel = resolveModel({ flag: params.model, env, confContents });

  // 3. Gate: the leading-dash refusal (C12) THEN the policy tier gate (C1–C7). deny →
  //    exit-3 analogue; ask without confirmed → exit-4 analogue instructing the DRIVER to
  //    ask the human; ask+confirmed or allow → proceed. All BEFORE any log write, so a
  //    refusal logs nothing (C24 gap parity).
  //
  // HONESTY BOUND (design input for M9): the MCP surface has NO per-argument permission
  // gate, so `confirmed:true` cannot be made to force a user prompt the way witness.md's
  // allowed-tools OMISSION of the COLLAB_CONFIRMED form makes Claude-auditing-Claude
  // impossible to self-authorise. Here the ask gate is instruction-layer (the error text
  // telling the driver the user must approve) PLUS the mechanical backstop that a
  // non-confirmed call cannot proceed, PLUS the tier/confirmed audit trail written into
  // the evidence entries so /collab:witness can check after the fact whether an ask-tier
  // consult claimed approval. That is NOT witness-grade parity — a driver that sets
  // confirmed:true without asking is caught only by audit, not prevented.
  const gate = gateModel(requestedModel, params.confirmed === true, { collabDir, env });
  if (!gate.ok) {
    return {
      ok: false,
      rootConflict,
      error: {
        kind: gate.refusal.kind,
        message: gate.refusal.message,
        exitAnalogue: gate.refusal.exitAnalogue,
        model: gate.refusal.model,
        tier: gate.refusal.tier,
      },
    };
  }

  // --- Past the gate: from here every path writes exactly one started + completed. ---
  const log = deps.log ?? new EvidenceLog({ env, cwd, collabDir });

  // 4. Evidence lifecycle. Mint a fresh run only when the caller did not thread one; a
  //    provided runId reuses that run (so a workflow's calls share one auditable unit).
  const runId = params.runId && params.runId.length > 0 ? params.runId : log.newRun(CONSULT_COMMAND);

  // 5. The model turn, via the UNMODIFIED collab-read agent (shared spine).
  const outcome = await runAgentLifecycle(
    {
      question: params.question,
      requestedModel,
      agent: CONSULT_AGENT,
      command: CONSULT_COMMAND,
      title: "collab_consult",
      runId,
      tier: gate.tier,
      confirmed: gate.confirmed,
      sessionId: params.sessionId,
      keepSession: params.keepSession === true,
    },
    { serve: deps.serve, log, messageTimeoutMs: deps.messageTimeoutMs },
  );

  if (outcome.ok) {
    const ok: ConsultOk = {
      ok: true,
      answer: outcome.text,
      rootConflict,
      attribution: {
        model: outcome.actualModel,
        requestedModel,
        agent: CONSULT_AGENT,
        runId,
        callId: outcome.callId,
      },
    };
    // Only expose the session id when the caller asked to keep it — otherwise the
    // session is deleted and its id is a dangling reference.
    if (params.keepSession === true) ok.sessionId = outcome.sessionId;
    return ok;
  }
  const modelLabel = requestedModel === "" ? "(opencode default)" : requestedModel;
  // agent-mismatch is a positive-direction addition over bash (which has no post-call
  // agent check); it has NO bash exit analogue, so exitAnalogue stays null like
  // call-failed — the kind + isError carry the fail-closed signal.
  const message =
    outcome.kind === "agent-mismatch"
      ? outcome.reason
      : `The consult call to '${modelLabel}' failed: ${outcome.reason}. No answer was produced.`;
  return {
    ok: false,
    rootConflict,
    error: {
      kind: outcome.kind,
      model: requestedModel,
      // null, NOT 0: bash propagates opencode's own non-zero status verbatim (C53) and
      // 0 means success — a numeric analogue here would collide with that. The failure
      // signal is kind + isError; the reason rides in `message`.
      exitAnalogue: null,
      message,
    },
  };
}

// --- MCP tool-result translation -------------------------------------------
/** The MCP CallToolResult wire shape this tool emits. The index signature lets this
 * concrete type match MCP's passthrough `CallToolResult` union member (rather than the
 * task variant) at the handler boundary. */
export interface McpToolResult {
  content: Array<{ type: "text"; text: string }>;
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
  [key: string]: unknown;
}

/**
 * Map a `ConsultResult` to the MCP wire shape. Kept PURE (no server/transport imports) so
 * the byte-exact-through-the-boundary test can drive it without side effects.
 *
 * Success: the byte-exact answer is BOTH the text block and `structuredContent.answer`,
 * alongside exact-id attribution (model/agent/runId/callId). Failure: the structured
 * error (naming model + tier) with `isError:true`, so the driver treats a refusal as a
 * refusal it must act on (ask the user, choose another model) — not a normal answer.
 */
export function consultToToolResult(r: ConsultResult): McpToolResult {
  if (r.ok) {
    const structured: Record<string, unknown> = { answer: r.answer, ...r.attribution };
    if (r.rootConflict) structured.rootConflict = r.rootConflict;
    // Surface the kept session id so the driver can thread a follow-up turn by id.
    if (r.sessionId) structured.sessionId = r.sessionId;
    return { content: [{ type: "text", text: r.answer }], structuredContent: structured };
  }
  const structured: Record<string, unknown> = { error: r.error };
  if (r.rootConflict) structured.rootConflict = r.rootConflict;
  return {
    content: [{ type: "text", text: r.error.message }],
    structuredContent: structured,
    isError: true,
  };
}
