/**
 * collab_panel — multi-model orchestration over the committed substrate (PLAN.md M6).
 *
 * Generalizes the single-call collab_consult flow (src/consult.ts) to a PANEL: ask the
 * SAME question to 2–3 models from (ideally) different families, concurrently, each
 * through the UNMODIFIED read-only `collab-read` agent, and return every model's answer
 * with EXACT-ID attribution (panel.md "Report the exact model ids used" — area-F command
 * surface; NOT C45, which is verify-not-relay). It is a TRANSPORT, not a synthesizer: there is no
 * tie-breaking or reconciliation here — the DRIVER (the `/collab:panel` command doc)
 * synthesizes and preserves disagreement. Keeping the tool a transport is what stops it
 * from silently substituting its own take for the panel's (the command doc's job).
 *
 * PER-CALL INDEPENDENCE (matches bash, where each panel member is its own `ask.sh`):
 *   - Model-set resolution is `resolvePanelModels` (C13/C14), WIRED not reimplemented —
 *     its dedup + <2-model + single-provider "diversity theater" warnings are surfaced in
 *     the result, never swallowed.
 *   - Each member is gated INDEPENDENTLY (`gateModel`): a deny-tier member yields a
 *     per-model policy error while the others still run; an ask-tier member without
 *     confirmed yields the consult-style ask error for THAT member; a leading-dash id
 *     yields a per-member model-id error. A refused member logs NOTHING (C24 gap parity).
 *   - A member whose model call THROWS records completed/failed and surfaces a per-model
 *     call-failed error; it NEVER aborts the other members (Promise.all resolves each to
 *     a result object, so no member's rejection can reject the whole panel).
 *   - The WHOLE panel refuses only when the resolved model set is EMPTY (C14 exit-2).
 *
 * CONFIRMED IS PANEL-WIDE (documented honestly): a single `confirmed:true` on the panel
 * call approves EVERY ask-tier member of THIS call — the human is asked once about "this
 * panel", not once per model. That is a deliberately wider scope than collab_consult's
 * single-model confirm; it is recorded per-member in the evidence entries (tier/confirmed)
 * so /collab:witness can still audit, after the fact, that an ask-tier member ran under a
 * claimed approval. Same non-witness-grade bound as consult: a driver that sets confirmed
 * without asking is caught by audit, not prevented.
 *
 * ONE RUN FOR THE WHOLE PANEL (C23/C43): a single runId groups the workflow. It is minted
 * up front (or threaded from `runId`) so all members log into one auditable unit; each
 * member still gets its OWN call_id and its own expect→started→completed lifecycle with
 * DISTINCT turns under the shared lock (the log layer already proves concurrent
 * distinct-turn integrity; the panel test pins it again at this level).
 */

import os from "node:os";
import { type ServeProvider } from "./client.js";
import { EvidenceLog } from "./log.js";
import {
  resolveRootWithConflict,
  gateModel,
  runAgentLifecycle,
  type McpToolResult,
} from "./consult.js";
import { readConfContents, resolvePanelModels } from "./config.js";
import { type PolicyTier } from "./policy.js";

/** The read-only agent every panel member uses, unmodified (C15/C47/C48). */
export const PANEL_AGENT = "collab-read";
/** The command label recorded in the evidence log (drives `/collab:witness`). */
export const PANEL_COMMAND = "/collab:panel";

// --- Params + deps ---------------------------------------------------------
export interface PanelParams {
  question: string;
  /** Explicit provider/model ids. Omit to fall back to $COLLAB_MODELS then conf (C13). */
  models?: string[];
  /** Thread this call into an existing run; omit to mint one for the whole panel. */
  runId?: string;
  /** Human approval for ANY ask-tier member of this panel call (panel-wide scope). */
  confirmed?: boolean;
}

export interface PanelDeps {
  serve: ServeProvider;
  env?: NodeJS.ProcessEnv;
  cwd?: string;
  home?: string;
  /** Injected in tests so root/policy/log share one collab dir; else resolved. */
  log?: EvidenceLog;
  messageTimeoutMs?: number;
}

// --- Result / error shapes -------------------------------------------------
export type PanelMemberErrorKind = "model-id" | "policy-deny" | "policy-ask" | "call-failed";

export interface PanelMemberError {
  kind: PanelMemberErrorKind;
  message: string;
  /** bash exit analogue: 2 model-id, 3 deny, 4 ask; null for a call-failed (see consult). */
  exitAnalogue: number | null;
  /** Present on policy errors: the tier that refused. */
  tier?: PolicyTier;
}

/** One panel member's outcome — exactly one of `text` / `error` is set. `model` is the
 * EXACT id (area-F command surface, panel.md): the resolved/actual id on success, the
 * requested id on a refusal. */
export interface PanelMemberResult {
  model: string;
  text?: string;
  error?: PanelMemberError;
  /** Set once the member reached the lifecycle (success OR call-failed); absent for a
   * pre-log refusal (model-id/deny/ask), which writes no call. */
  callId?: string;
}

export interface PanelOk {
  ok: true;
  runId: string;
  /** Per-member results in INPUT ORDER; exact-id attribution (area-F command surface). */
  results: PanelMemberResult[];
  /** resolvePanelModels warnings (dedup, <2 models, single-provider) — surfaced, C14. */
  warnings: string[];
  rootConflict?: string;
}

export interface PanelFail {
  ok: false;
  /** The whole panel refused: the resolved model set was empty (C14 exit-2). */
  error: { kind: "no-models"; message: string; exitAnalogue: number };
  warnings: string[];
  rootConflict?: string;
}

export type PanelResult = PanelOk | PanelFail;

/**
 * Run one panel. Never throws for an expected refusal or a member failure — both are
 * data. A member's model call that throws is caught inside `runAgentLifecycle` and
 * surfaced as a per-member `call-failed`; `Promise.all` therefore never rejects.
 */
export async function panel(params: PanelParams, deps: PanelDeps): Promise<PanelResult> {
  const env = deps.env ?? process.env;
  const cwd = deps.cwd ?? process.cwd();
  const home = deps.home ?? os.homedir();

  // 1. Resolve the config root ONCE; surface a multi-root conflict.
  const rootRes = resolveRootWithConflict(env, cwd, home);
  const collabDir = rootRes.root;
  const rootConflict = rootRes.conflict;

  // 2. Resolve the panel's model set (args > $COLLAB_MODELS > conf), WIRING C13/C14's
  //    resolvePanelModels — dedup, order, and the diversity/shape warnings intact.
  const confContents = readConfContents(collabDir, env);
  const panelRes = resolvePanelModels({ args: params.models, env, confContents });
  if (panelRes.error !== undefined || panelRes.models.length === 0) {
    return {
      ok: false,
      warnings: panelRes.warnings,
      rootConflict,
      error: {
        kind: "no-models",
        message:
          panelRes.error ??
          "no models resolved for the panel. Pass provider/model ids, set COLLAB_MODELS, or add a COLLAB_MODELS= line to collab.conf.local.",
        exitAnalogue: panelRes.exitCode ?? 2,
      },
    };
  }

  // 3. One run for the whole panel (C23/C43). Mint up front so every member logs into the
  //    same auditable unit; a threaded runId reuses that run.
  const log = deps.log ?? new EvidenceLog({ env, cwd, collabDir });
  const runId = params.runId && params.runId.length > 0 ? params.runId : log.newRun(PANEL_COMMAND);
  const confirmed = params.confirmed === true;

  // 4. Members run CONCURRENTLY; each is gated + logged independently. One member's
  //    refusal or failure never touches another's result (order preserved by Promise.all).
  const results = await Promise.all(
    panelRes.models.map(async (model): Promise<PanelMemberResult> => {
      const gate = gateModel(model, confirmed, { collabDir, env });
      if (!gate.ok) {
        // A pre-log refusal: no call_id, nothing written for this member (gap parity).
        return {
          model,
          error: {
            kind: gate.refusal.kind,
            message: gate.refusal.message,
            exitAnalogue: gate.refusal.exitAnalogue,
            tier: gate.refusal.tier,
          },
        };
      }
      const outcome = await runAgentLifecycle(
        {
          question: params.question,
          requestedModel: model,
          agent: PANEL_AGENT,
          command: PANEL_COMMAND,
          title: "collab_panel",
          runId,
          tier: gate.tier,
          confirmed: gate.confirmed,
        },
        { serve: deps.serve, log, messageTimeoutMs: deps.messageTimeoutMs },
      );
      if (outcome.ok) {
        return { model: outcome.actualModel, text: outcome.text, callId: outcome.callId };
      }
      return {
        model,
        callId: outcome.callId,
        error: {
          kind: "call-failed",
          exitAnalogue: null,
          message: `The panel call to '${model}' failed: ${outcome.reason}. No answer was produced.`,
        },
      };
    }),
  );

  return { ok: true, runId, results, warnings: panelRes.warnings, rootConflict };
}

// --- MCP tool-result translation -------------------------------------------
/**
 * Render a human-readable digest for the tool's text block. The DRIVER synthesizes from
 * `structuredContent` (the machine-readable per-member results); this text is a readable
 * mirror so a bare text-only client still sees every voice and every warning.
 */
function renderPanelText(r: PanelOk): string {
  const lines: string[] = [];
  lines.push(`Panel of ${r.results.length} model(s) — run ${r.runId || "(logging off)"}.`);
  if (r.rootConflict) lines.push(`Root: ${r.rootConflict}`);
  if (r.warnings.length > 0) {
    lines.push("");
    lines.push("Warnings:");
    for (const w of r.warnings) lines.push(`  - ${w}`);
  }
  for (const m of r.results) {
    lines.push("");
    lines.push(`## ${m.model}`);
    if (m.error) lines.push(`ERROR (${m.error.kind}): ${m.error.message}`);
    else lines.push(m.text ?? "");
  }
  return lines.join("\n");
}

/**
 * Map a `PanelResult` to the MCP wire shape. On success the text block is the readable
 * digest and `structuredContent` carries the per-member results + warnings + runId (the
 * driver's real input). A whole-panel refusal (empty set) sets `isError:true` so the
 * driver treats it as a refusal to act on — a per-member error does NOT set `isError`,
 * because the panel call itself succeeded (that error is data about one voice).
 */
export function panelToToolResult(r: PanelResult): McpToolResult {
  if (!r.ok) {
    const structured: Record<string, unknown> = { error: r.error, warnings: r.warnings };
    if (r.rootConflict) structured.rootConflict = r.rootConflict;
    return {
      content: [{ type: "text", text: r.error.message }],
      structuredContent: structured,
      isError: true,
    };
  }
  const structured: Record<string, unknown> = {
    runId: r.runId,
    results: r.results,
    warnings: r.warnings,
  };
  if (r.rootConflict) structured.rootConflict = r.rootConflict;
  return { content: [{ type: "text", text: renderPanelText(r) }], structuredContent: structured };
}
