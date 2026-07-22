# Spike report — TypeScript MCP server fronting `opencode serve`

Run 2026-07-22 against the exit criteria in PLAN.md "Rewrite: TypeScript MCP server".
Verdict: **the shape is viable — proceed-eligible.** Criteria 1, 2, 4 PASS; criterion 3
mechanically proven, interactive half left for the maintainer (below). Two real
findings for the rewrite came out of the e2e run.

## Criterion results

1. **Permission maps hold through the server API — PASS (the kill criterion).**
   `opencode serve` loads the unmodified `collab-read` def and enforces it at the tool
   layer: an allowed `read` completed; a `config.env` read was **denied by the `*.env`
   glob with the rule echoed in the tool error** (canary value never appeared anywhere
   in the envelope); a write attempt found no write tool offered at all (`"*": deny`
   floor); the same server wrote fine as unrestricted `build` (control), proving the
   denial is the map, not a broken server. Probe method note: the first `.env` attempt
   produced a model *compliance* refusal (no tool call) — weak evidence; the probe was
   re-run with an innocuous framing so the model actually invoked the tool and the
   *floor* was measured, per the AGENTS.md canary rule.
2. **Byte-exact capture — PASS.** Three-way byte-identical: the text the MCP client
   received == the capture entry's `response` == the final text part in the session
   history. Full history (including tool parts with `state.{status,input,error,output}`)
   is captured from `GET /session/{id}/message` — the synchronous message response
   alone is NOT sufficient (it returns only the last assistant message, no tool parts).
3. **Claude Code integration — PASS (UX half closed 2026-07-22).** Maintainer's live
   session: default mode prompts per call; "don't ask again" persists a per-tool,
   per-project allow (`mcp__collab-spike__collab_consult` in `.claude/settings.local.json`,
   verified) and later calls run silently. Auto Mode never prompts (blanket-approves MCP
   tools — a coarser gate than today's per-pattern grants; noted, not blocking).
   Original criterion text follows for the record. A real headless
   session (`claude -p --mcp-config … --strict-mcp-config`) exposed and invoked
   `collab_consult` end-to-end: Claude Code → MCP stdio → `opencode serve` →
   `collab-read` → free model → target file, correct marker returned, capture written.
   What this cannot show is the *interactive* one-time approval flow — the maintainer
   should open a live session with `mcp.json.example` registered and confirm the
   approval prompt appears once and feels right. Until then this criterion is
   incomplete, not failed.
4. **Session lifecycle — PASS.** Session created with the agent, deleted after the
   call (`GET` → 404 against the still-running serve), and no serve process survived
   the MCP SDK client's close (exact-pid check).

## Findings for the rewrite (both from the live e2e, neither fatal)

- **Orphaned `opencode serve` after Claude Code teardown — reproduced in BOTH paths.**
  The spike server's cleanup handlers (`exit`/signal hooks + process-group kill) work
  under the MCP SDK client but did NOT fire when Claude Code tore the MCP server down
  at session end — first seen under headless `claude -p`, then confirmed by the
  maintainer's interactive G0 session (2026-07-22): `ps -C opencode` showed a surviving
  serve after the session. The production server must treat stdin EOF/transport close
  as a hard shutdown trigger (and consider an idle timeout on the serve child) rather
  than relying on signal handlers alone.
- **`rawHistoryFile` is recorded relative to the server process cwd**, which is
  whatever directory Claude Code spawned it from — the reference breaks when the log
  is read from anywhere else. Store it absolute, or relative to the log file.

## Gotchas carried forward (from the probe + wiring agents)

- Message-input model shape `{providerID, modelID}` differs from session-create's
  `{id, providerID}`.
- `/session` and `/api/session` both exist; the unprefixed surface works.
- `opencode serve` is **unsecured by default** (plaintext HTTP, warning printed);
  loopback-only is fine for local use, `OPENCODE_SERVER_PASSWORD` exists for anything
  else. The permission map, not the transport, is what enforces read-only.
- `pgrep -f` self-matches its own pattern — use `ps -C opencode` or exact-pid checks.
- Tool parts in history are `type:"tool"` with `tool:"read"`, not a `read` part type.

## Artifacts

- `src/` — server, wiring (`COLLAB_SPIKE_REAL=1` gates live vs stub), byte-exact capture.
- `npm test` (offline, 18 checks) and `npm run test:live` (6 live checks) — both green.
- `mcp.json.example` — registration snippet for the interactive UX check.

Testing hygiene held throughout: free models only (`opencode/deepseek-v4-flash-free`),
every model/HTTP call timeout-bounded, probes ran in disposable scratch projects, no
repo payload files touched.
