# mcp-consult spike

Minimal TS MCP server for PLAN.md "Rewrite: TypeScript MCP server".
Exposes one stdio MCP tool, `collab_consult`. opencode is now wired: the tool
lazily spawns `opencode serve` (loopback, free port) from a project dir, creates
a `collab-read` session, sends the question, captures the full raw history
byte-exactly, deletes the session, and reuses the server across calls.

## Tests

- `npm test` — **offline stub** round-trip: spawns the server, calls the tool,
  checks byte-exact question round-trip + capture log via `test/client.ts`. No
  model call. Selects the stub because `COLLAB_SPIKE_REAL` is unset.
- `npm run test:live` — **live** end-to-end via `test/live.ts`. Builds a
  disposable project under the scratchpad (the `collab-read` agent def + a
  `notes.md` marker), points `COLLAB_PROJECT_DIR` at it, drives the MCP server
  over stdio, and asserts: (a) the marker comes back, (b) the capture entry's
  response is byte-identical to what the client received, (c) the raw history
  holds a completed `read` tool part, (d) the session was deleted (checked
  against the live serve before shutdown), (e) no `opencode serve` process
  survives client close. Free model only, every call timeout-bounded. Requires a
  logged-in `opencode` on PATH.

## Environment

- `COLLAB_SPIKE_REAL=1` — use the real opencode path (default: stub).
- `COLLAB_PROJECT_DIR` — project dir whose `.opencode/agent/` holds the defs
  (default: `process.cwd()`); `opencode serve` runs from here.
- `COLLAB_SPIKE_MODEL` — model, `provider/model` (default
  `opencode/deepseek-v4-flash-free`).
- `COLLAB_SPIKE_LOG` — capture JSONL path (default `./spike-log.jsonl`); the raw
  history is written to a referenced sibling `*.history.json`.
- `COLLAB_SPIKE_SERVE_INFO` — optional path the server writes `{port,baseUrl,pid}`
  to once ready (used by the live test to verify session/process lifecycle).

Status: **live wiring done — spike exit criteria 2 (byte-exact capture) and 4
(session lifecycle incl. cleanup) validated by `npm run test:live`.**
