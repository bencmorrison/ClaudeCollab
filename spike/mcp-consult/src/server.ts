import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { askOpencode, stubAskOpencode, shutdownOpencode } from "./opencode.js";
import { recordCapture } from "./capture.js";

const TOOL_NAME = "collab_consult";

// Offline `npm test` runs the stub; the live path (`COLLAB_SPIKE_REAL=1`) spawns
// opencode and consults the `collab-read` agent for real.
const REAL = process.env.COLLAB_SPIKE_REAL === "1";
const ask = REAL ? askOpencode : stubAskOpencode;

const server = new Server(
  { name: "mcp-consult-spike", version: "0.0.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: TOOL_NAME,
      description: REAL
        ? "Consult another model via opencode's read-only collab-read agent."
        : "STUB: consult another model (opencode wiring not implemented yet — this is a spike skeleton).",
      inputSchema: {
        type: "object",
        properties: {
          question: {
            type: "string",
            description: "The question to ask.",
          },
          model: {
            type: "string",
            description: "Optional model identifier to route to.",
          },
        },
        required: ["question"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name !== TOOL_NAME) {
    throw new Error(`Unknown tool: ${request.params.name}`);
  }

  const args = request.params.arguments as { question?: unknown; model?: unknown } | undefined;
  const question = args?.question;
  if (typeof question !== "string") {
    throw new Error("collab_consult requires a string 'question' argument");
  }
  const model = typeof args?.model === "string" ? args.model : undefined;

  const answer = await ask(question, model);

  await recordCapture(
    {
      timestamp: new Date().toISOString(),
      tool: TOOL_NAME,
      question,
      response: answer.text,
      model,
      sessionId: answer.sessionId,
    },
    answer.rawHistory,
  );

  return {
    content: [
      {
        type: "text",
        text: answer.text,
      },
    ],
  };
});

// When the client closes the stdio transport, tear down the opencode serve
// process so nothing is orphaned (belt-and-braces with opencode.ts's signal
// and exit handlers).
server.onclose = () => {
  shutdownOpencode();
  process.exit(0);
};

const transport = new StdioServerTransport();
await server.connect(transport);
