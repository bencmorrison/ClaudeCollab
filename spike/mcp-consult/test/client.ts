import { readFile, rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectDir = path.resolve(__dirname, "..");
const tsxBin = path.join(projectDir, "node_modules", ".bin", "tsx");
const serverEntry = path.join(projectDir, "src", "server.ts");
const captureLog = path.join(projectDir, "test", ".test-spike-log.jsonl");

const QUESTION = 'Line one\nLine "two" with quotes\nUnicode: café ☃ 😀\nTab:\tEnd.';

let failures = 0;

function check(condition: boolean, message: string): void {
  if (condition) {
    console.log(`  PASS: ${message}`);
  } else {
    failures += 1;
    console.error(`  FAIL: ${message}`);
  }
}

async function main(): Promise<void> {
  await rm(captureLog, { force: true });

  const transport = new StdioClientTransport({
    command: tsxBin,
    args: [serverEntry],
    cwd: projectDir,
    env: { ...process.env, COLLAB_SPIKE_LOG: captureLog } as Record<string, string>,
  });

  const client = new Client({ name: "mcp-consult-spike-test-client", version: "0.0.0" });

  console.log("Connecting to server over stdio...");
  await client.connect(transport);

  console.log("Listing tools...");
  const toolsResult = await client.listTools();
  const tool = toolsResult.tools.find((t) => t.name === "collab_consult");
  check(tool !== undefined, "collab_consult tool is present");

  if (tool) {
    const schema = tool.inputSchema as {
      type?: string;
      properties?: Record<string, { type?: string }>;
      required?: string[];
    };
    check(schema.type === "object", "inputSchema.type is 'object'");
    check(schema.properties?.question?.type === "string", "inputSchema.properties.question is a string");
    check(schema.properties?.model?.type === "string", "inputSchema.properties.model is a string");
    check(
      Array.isArray(schema.required) && schema.required.includes("question"),
      "inputSchema.required includes 'question'",
    );
    check(
      Array.isArray(schema.required) && !schema.required.includes("model"),
      "inputSchema.required does NOT include 'model' (optional)",
    );
  }

  console.log("Calling collab_consult with a question containing newlines/quotes/unicode...");
  const callResult = await client.callTool({
    name: "collab_consult",
    arguments: { question: QUESTION, model: "test-model" },
  });

  const content = callResult.content as Array<{ type: string; text?: string }>;
  check(Array.isArray(content) && content.length === 1, "tool call returned exactly one content block");
  const responseText = content[0]?.text ?? "";
  check(content[0]?.type === "text", "content block type is 'text'");
  check(responseText.includes("STUB"), "response is clearly marked STUB");
  check(
    responseText.endsWith(QUESTION),
    "response round-trips the exact question byte-for-byte (newlines/quotes/unicode intact)",
  );

  await client.close();

  console.log("Checking capture log...");
  const raw = await readFile(captureLog, "utf8");
  const lines = raw.split("\n").filter((l) => l.length > 0);
  check(lines.length === 1, "capture log has exactly one entry");

  const entry = JSON.parse(lines[0] ?? "{}") as {
    timestamp?: string;
    tool?: string;
    question?: string;
    response?: string;
    model?: string;
    sessionId?: string;
  };
  check(entry.tool === "collab_consult", "captured entry has tool = collab_consult");
  check(entry.question === QUESTION, "captured question matches byte-exactly");
  check(entry.response === responseText, "captured response matches the tool's response byte-exactly");
  check(entry.model === "test-model", "captured model matches");
  check(typeof entry.sessionId === "string" && entry.sessionId.length > 0, "captured sessionId present");
  check(typeof entry.timestamp === "string" && !Number.isNaN(Date.parse(entry.timestamp)), "captured timestamp is a valid date string");

  await rm(captureLog, { force: true });

  if (failures > 0) {
    console.error(`\n${failures} check(s) failed.`);
    process.exit(1);
  }
  console.log("\nAll checks passed.");
}

main().catch((err) => {
  console.error("Test client crashed:", err);
  process.exit(1);
});
