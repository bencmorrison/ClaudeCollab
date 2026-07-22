import { appendFile, writeFile } from "node:fs/promises";
import path from "node:path";

/**
 * Append-only JSONL capture writer — one summary entry per collab_consult call,
 * plus (for the live opencode path) the full raw message history persisted as a
 * referenced sibling file.
 *
 * Byte-exactness (spike exit criterion 2): `response` is written to the JSON
 * string field exactly as received — no .trim(), no whitespace/unicode
 * normalization. JSON string encoding (\n, \", unicode) round-trips exactly via
 * JSON.parse, so the value read back is identical to what the MCP client got.
 */

export interface CaptureEntry {
  timestamp: string;
  tool: string;
  question: string;
  response: string;
  model?: string;
  sessionId: string;
  /**
   * Relative path (from the log file's directory) to the sibling JSON file
   * holding the raw `GET /session/{id}/message` history. Absent for the stub.
   */
  rawHistoryFile?: string;
}

function logPath(): string {
  return process.env.COLLAB_SPIKE_LOG ?? "./spike-log.jsonl";
}

let seq = 0;

/**
 * Record one call. When `rawHistory` is provided, its JSON is first written to a
 * sibling file next to the log and referenced from the entry via
 * `rawHistoryFile`, so a call appends TWO artifacts: the summary line and the
 * raw envelope.
 */
export async function recordCapture(entry: CaptureEntry, rawHistory?: unknown): Promise<void> {
  const log = logPath();
  const finalEntry: CaptureEntry = { ...entry };

  if (rawHistory !== undefined) {
    const dir = path.dirname(log);
    const base = path.basename(log);
    const rawName = `${base}.${Date.now()}-${seq++}.history.json`;
    await writeFile(path.join(dir, rawName), JSON.stringify(rawHistory, null, 2) + "\n", "utf8");
    finalEntry.rawHistoryFile = rawName;
  }

  const line = JSON.stringify(finalEntry) + "\n";
  await appendFile(log, line, "utf8");
}
