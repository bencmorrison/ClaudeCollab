/**
 * LIVE end-to-end test — exercises the real opencode wiring (NOT the stub).
 *
 * Validates spike exit criteria 2 (byte-exact capture) and 4 (session lifecycle
 * incl. cleanup) from PLAN.md "Rewrite: TypeScript MCP server".
 *
 * Requires a logged-in opencode on PATH and calls a FREE model
 * (opencode/deepseek-v4-flash-free). Every model call is timeout-bounded and
 * every spawned process is killed on every exit path.
 *
 * Run: `npm run test:live`
 */

import { mkdtemp, mkdir, copyFile, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectDir = path.resolve(__dirname, "..");
const repoRoot = path.resolve(projectDir, "..", "..");
const tsxBin = path.join(projectDir, "node_modules", ".bin", "tsx");
const serverEntry = path.join(projectDir, "src", "server.ts");
const agentDef = path.join(repoRoot, ".opencode", "agent", "collab-read.md");

const scratchBase =
  process.env.CLAUDE_SCRATCH ||
  "/tmp/claude-1000/-workspaces-ClaudeCollab/0f1df3a3-c36d-41a2-8d6c-64dca95a4a83/scratchpad";

const MARKER = `MARKER-${randomBytes(6).toString("hex").toUpperCase()}`;
const MODEL = process.env.COLLAB_SPIKE_MODEL || "opencode/deepseek-v4-flash-free";

// Hard cap on the whole run so a stuck model call can never hang CI.
const OVERALL_TIMEOUT_MS = 240_000;

let failures = 0;
function check(condition: boolean, message: string): void {
  if (condition) {
    console.log(`  PASS: ${message}`);
  } else {
    failures += 1;
    console.error(`  FAIL: ${message}`);
  }
}

function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === "EPERM"; // exists but not ours
  }
}

async function main(): Promise<void> {
  const tmpRoot = await mkdtemp(path.join(scratchBase, "mcp-live-"));
  const projRoot = path.join(tmpRoot, "proj");
  const logPath = path.join(tmpRoot, "spike-log.jsonl");
  const serveInfoPath = path.join(tmpRoot, "serve-info.json");

  // Disposable project: the collab-read agent def + a notes file with a marker.
  await mkdir(path.join(projRoot, ".opencode", "agent"), { recursive: true });
  await copyFile(agentDef, path.join(projRoot, ".opencode", "agent", "collab-read.md"));
  await writeFile(
    path.join(projRoot, "notes.md"),
    `# Project notes\n\nThe secret project marker is ${MARKER}.\nDo not lose it.\n`,
    "utf8",
  );

  const transport = new StdioClientTransport({
    command: tsxBin,
    args: [serverEntry],
    cwd: projectDir,
    env: {
      ...process.env,
      COLLAB_SPIKE_REAL: "1",
      COLLAB_PROJECT_DIR: projRoot,
      COLLAB_SPIKE_LOG: logPath,
      COLLAB_SPIKE_SERVE_INFO: serveInfoPath,
      COLLAB_SPIKE_MODEL: MODEL,
    } as Record<string, string>,
  });

  const client = new Client({ name: "mcp-consult-spike-live-client", version: "0.0.0" });

  let clientClosed = false;
  const closeClient = async () => {
    if (clientClosed) return;
    clientClosed = true;
    await client.close().catch(() => {});
  };

  try {
    console.log(`Connecting to live MCP server (model=${MODEL}, marker=${MARKER})...`);
    await client.connect(transport);

    console.log("Calling collab_consult (real opencode, collab-read agent)...");
    const callResult = await client.callTool(
      {
        name: "collab_consult",
        arguments: {
          question:
            "Read the file notes.md in this project and reply with the exact secret project " +
            "marker string it contains. Return just the marker.",
        },
      },
      undefined,
      { timeout: 200_000 },
    );

    const content = callResult.content as Array<{ type: string; text?: string }>;
    const responseText = content?.[0]?.text ?? "";
    console.log(`  server response: ${JSON.stringify(responseText)}`);

    // (a) response contains the marker
    check(responseText.includes(MARKER), `(a) response contains the marker ${MARKER}`);

    // Read the capture log + referenced raw history.
    const raw = await readFile(logPath, "utf8");
    const lines = raw.split("\n").filter((l) => l.length > 0);
    check(lines.length === 1, "capture log has exactly one summary entry");
    const entry = JSON.parse(lines[0] ?? "{}") as {
      response?: string;
      sessionId?: string;
      rawHistoryFile?: string;
    };

    // (b) capture entry response byte-identical to what the client received
    check(
      entry.response === responseText,
      "(b) capture entry response is byte-identical to the client's response",
    );

    // (c) raw history contains a completed `read` tool part
    let hasCompletedRead = false;
    let finalTextInHistory = "";
    if (entry.rawHistoryFile) {
      const histRaw = await readFile(path.join(tmpRoot, entry.rawHistoryFile), "utf8");
      const history = JSON.parse(histRaw) as Array<{
        parts?: Array<{ type?: string; tool?: string; text?: string; state?: { status?: string } }>;
      }>;
      for (const msg of history) {
        for (const p of msg.parts ?? []) {
          if (p.type === "tool" && p.tool === "read" && p.state?.status === "completed") {
            hasCompletedRead = true;
          }
          if (p.type === "text" && typeof p.text === "string") finalTextInHistory = p.text;
        }
      }
    }
    check(hasCompletedRead, "(c) raw history contains a completed `read` tool part");
    // Reinforce criterion 2: the history's final text part equals what we returned.
    check(
      finalTextInHistory === responseText,
      "(2) history's final text part is byte-identical to the client's response",
    );

    // (d) session was deleted — verify against the LIVE serve (before shutdown).
    const serveInfo = JSON.parse(await readFile(serveInfoPath, "utf8")) as {
      port: number;
      baseUrl: string;
      pid: number;
    };
    const sid = entry.sessionId ?? "";
    const getRes = await fetch(`${serveInfo.baseUrl}/session/${sid}/message`, {
      signal: AbortSignal.timeout(10_000),
    });
    let inList = true;
    if (getRes.status !== 404) {
      const listRes = await fetch(`${serveInfo.baseUrl}/session`, {
        signal: AbortSignal.timeout(10_000),
      });
      const list = (await listRes.json()) as Array<{ id?: string }>;
      inList = list.some((s) => s.id === sid);
    }
    check(
      getRes.status === 404 || !inList,
      `(d) session ${sid} was deleted (GET → ${getRes.status}${getRes.status === 404 ? "" : `, in list: ${inList}`})`,
    );

    // (e) no `opencode serve` process remains after client close.
    const servePid = serveInfo.pid;
    check(pidAlive(servePid), "serve process was alive during the call (sanity)");
    await closeClient();
    // Give the serve process a moment to be reaped after the transport closes.
    const deadline = Date.now() + 15_000;
    while (pidAlive(servePid) && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 200));
    }
    check(!pidAlive(servePid), `(e) no opencode serve process remains after client close (pid ${servePid})`);
  } finally {
    await closeClient();
    await rm(tmpRoot, { recursive: true, force: true }).catch(() => {});
  }

  if (failures > 0) {
    console.error(`\n${failures} check(s) failed.`);
    process.exit(1);
  }
  console.log("\nAll live checks passed. Criteria 2 (byte-exact capture) and 4 (session lifecycle) validated.");
}

const guard = setTimeout(() => {
  console.error(`Live test exceeded ${OVERALL_TIMEOUT_MS}ms — aborting.`);
  process.exit(1);
}, OVERALL_TIMEOUT_MS);
guard.unref();

main().catch((err) => {
  console.error("Live test crashed:", err);
  process.exit(1);
});
