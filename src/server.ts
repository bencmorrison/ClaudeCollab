/**
 * MCP stdio server (PLAN.md milestone M1).
 *
 * Exposes ONE diagnostic tool, `collab_status`, whose job is to exercise the full
 * `opencode serve` lifecycle end-to-end: it ensures the serve child is up, reads its
 * version and agent list, and reports them. The real collab tools (consult, panel, …)
 * arrive in M5+; deliberately none are registered here.
 *
 * The lifecycle's shutdown triggers are wired to THIS process's stdin and to the MCP
 * transport — the pair that actually fire under Claude Code teardown (see lifecycle.ts).
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { OpencodeLifecycle, type ServeHandle } from "./lifecycle.js";

const TOOL_NAME = "collab_status";
const HTTP_MS = 10_000;

const lifecycle = new OpencodeLifecycle();

interface CollabStatus {
  opencodeVersion: string | null;
  port: number;
  pid: number;
  agentCount: number;
}

async function collabStatus(): Promise<CollabStatus> {
  return lifecycle.withServe(async (h: ServeHandle) => {
    // Version + liveness from the health endpoint (GET /doc is used for readiness;
    // /global/health additionally carries the opencode binary version).
    let opencodeVersion: string | null = null;
    try {
      const health = (await httpJson(`${h.baseUrl}/global/health`)) as { version?: unknown };
      if (typeof health.version === "string") opencodeVersion = health.version;
    } catch {
      /* leave null — the serve is up (withServe proved readiness) but health may lag */
    }

    const agents = (await httpJson(`${h.baseUrl}/agent`)) as unknown;
    const agentCount = Array.isArray(agents) ? agents.length : 0;

    return { opencodeVersion, port: h.port, pid: h.pid, agentCount };
  });
}

async function httpJson(url: string): Promise<unknown> {
  const res = await fetch(url, { signal: AbortSignal.timeout(HTTP_MS) });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`GET ${url} → ${res.status} ${res.statusText} ${body}`);
  }
  return res.json();
}

const server = new Server(
  { name: "claudecollab", version: "0.0.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: TOOL_NAME,
      description:
        "Diagnostic: ensure the opencode serve child is running and report its version, " +
        "port, pid, and agent count. Exercises the full lifecycle; takes no arguments.",
      inputSchema: { type: "object", properties: {}, additionalProperties: false },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name !== TOOL_NAME) {
    throw new Error(`Unknown tool: ${request.params.name}`);
  }
  const status = await collabStatus();
  return {
    content: [{ type: "text", text: JSON.stringify(status) }],
  };
});

const transport = new StdioServerTransport();

// PRIMARY teardown wiring: stdin EOF and transport close kill the serve child and
// exit this process. Signals/`exit` are only the second layer (installed inside).
//
// COLLAB_TEARDOWN_MODE=spike is a TEST-ONLY seam: it drops the stdin watch and wires
// only the transport (plus the signal/exit backstop) — i.e. exactly the spike's
// approach. The flagship orphan test drives production and spike modes through the
// same code so the green/red difference is precisely the stdin watch, nothing else.
// It has no effect on normal operation and is never set outside the test suite.
const teardownSources =
  process.env.COLLAB_TEARDOWN_MODE === "spike"
    ? { transport }
    : { stdin: process.stdin, transport };
lifecycle.attachShutdownTriggers(teardownSources, { exitProcess: true });

await server.connect(transport);
