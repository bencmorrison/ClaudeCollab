/**
 * Canonical JSON + hashing — the byte-for-byte bridge to the bash evidence layer
 * (CONTRACT.md area D, C25/C27).
 *
 * The bash `log.sh` writes every entry with `jq -cS` (compact, KEY-SORTED) and its
 * `verify` recomputes hashes over `jq -cjS del(.entry_hash)`. For a TS-written log to
 * pass `bash log.sh verify` — and a bash-written log to pass ours — this module must
 * serialize IDENTICAL bytes to jq: same key order, same separators, same string
 * escaping. That is not an assumption; it was measured.
 *
 * WHAT WAS VERIFIED (2026-07-22, jq 1.7, node 22):
 *   - Escaping was compared against jq -cS over EVERY BMP code point 0x00–0xFFFF
 *     (skipping surrogate halves) plus a set of astral code points. `JSON.stringify`
 *     and jq agreed on all of them EXCEPT ONE: U+007F (DEL), which jq emits as
 *     `\u007f` while `JSON.stringify` emits raw. Every control char (0x00–0x1F, incl.
 *     the \b \t \n \f \r short forms), quote, backslash, and non-ASCII byte matched.
 *     So the canonical string encoder is `JSON.stringify` + a single post-fixup that
 *     escapes any literal DEL byte as `\u007f`.
 *   - The whole pipeline (sorted keys, compact form, entry_hash appended LAST rather
 *     than in sorted position — a bash quirk of `jq -cS … | jq -c '. + {entry_hash}'`)
 *     was replayed against three real bash-written lines: entry_hash, the exact stored
 *     bytes, and the prev_hash chain all reproduced.
 *
 * Because the only divergence is U+007F, we build on `JSON.stringify` (fast, correct
 * for everything else) rather than hand-rolling an escaper that could drift from jq on
 * some code point we forgot to test.
 */

import { createHash } from "node:crypto";

/** A JSON value the evidence layer serializes. Our schema only ever holds strings,
 * finite integers, booleans, null, and flat objects — but arrays/nested objects are
 * handled recursively so this stays a general canonical serializer (jq -S is
 * recursive, so we are too). */
export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

/**
 * Encode a single string exactly as `jq -cS` would.
 *
 * `JSON.stringify` matches jq for every code point except U+007F (DEL), which jq
 * escapes as `\u007f`. The only place a raw 0x7f can appear in `JSON.stringify`'s
 * output is as a literal DEL from the input string (it is never part of an escape
 * sequence jq and JS disagree on), so replacing every raw 0x7f with `\u007f` is a
 * safe, exact fixup. Verified over the full BMP + astral samples.
 */
export function encodeJsonString(s: string): string {
  return JSON.stringify(s).replace(/\u007f/g, "\\u007f");
}

/** Encode a finite number as jq would. The evidence schema uses only integers
 * (exit codes, turns, byte/file counts); we reject non-finite values loudly rather
 * than emit `null`/`Infinity` that would silently diverge from jq. */
function encodeNumber(n: number): string {
  if (!Number.isFinite(n)) {
    throw new Error(`canonical: refusing to serialize non-finite number ${n}`);
  }
  // For integers (all this schema uses) String(n) === jq's output. JSON.stringify
  // is the fallback for the fractional case, which this schema never hits.
  return Number.isInteger(n) ? String(n) : JSON.stringify(n);
}

/**
 * Serialize a value to canonical JSON: recursively key-sorted, compact (no spaces),
 * jq-identical string escaping. This is the exact byte string `jq -cS` produces for
 * the same value, and the exact input `_sha` hashes in bash.
 *
 * Key order: jq -S sorts by code point. All evidence-layer keys are ASCII, for which
 * JS's default string comparison already matches code-point order; the comparator is
 * spelled out anyway so a future non-ASCII key can't silently reorder.
 */
export function canonicalStringify(value: JsonValue): string {
  if (value === null) return "null";
  const t = typeof value;
  if (t === "boolean") return value ? "true" : "false";
  if (t === "number") return encodeNumber(value as number);
  if (t === "string") return encodeJsonString(value as string);
  if (Array.isArray(value)) {
    return "[" + value.map((v) => canonicalStringify(v)).join(",") + "]";
  }
  if (t === "object") {
    const obj = value as { [key: string]: JsonValue };
    const keys = Object.keys(obj).sort(compareCodePoints);
    const parts = keys.map((k) => encodeJsonString(k) + ":" + canonicalStringify(obj[k]));
    return "{" + parts.join(",") + "}";
  }
  throw new Error(`canonical: unserializable value of type ${t}`);
}

/** Compare two strings by Unicode code point (jq -S's sort order). For the ASCII
 * keys this schema uses it is identical to the default UTF-16 comparison; it differs
 * only for astral characters, which keys never contain. */
function compareCodePoints(a: string, b: string): number {
  if (a === b) return 0;
  return a < b ? -1 : 1;
}

/** sha256 hex of a string's UTF-8 bytes — bash's `_sha` (sha256sum/shasum). */
export function sha256Hex(s: string): string {
  return createHash("sha256").update(s, "utf8").digest("hex");
}

/** sha256 hex of raw bytes — for hashing a file's exact contents (e.g. a patch). */
export function sha256HexBytes(buf: Buffer): string {
  return createHash("sha256").update(buf).digest("hex");
}

/**
 * Build the STORED line for an entry, byte-identical to bash.
 *
 * Bash produces the line in two jq steps: `jq -cS` sorts the payload (incl. prev_hash,
 * and turn for `started`), then `jq -c '. + {entry_hash}'` appends entry_hash to the
 * ALREADY-sorted object — so entry_hash lands LAST, not in its sorted position. We
 * reproduce that quirk exactly, because the whole stored line's bytes feed the next
 * line's prev_hash (the chain), and a byte-identical layout is what lets bash and TS
 * writers coexist in one run.
 *
 * @param payload the entry WITHOUT entry_hash (must already include prev_hash/turn).
 * @returns `{ line, entryHash }` where entryHash = sha256(canonical(payload)).
 */
export function buildEntryLine(payload: { [key: string]: JsonValue }): {
  line: string;
  entryHash: string;
} {
  const canonical = canonicalStringify(payload);
  const entryHash = sha256Hex(canonical);
  // Insert `,"entry_hash":"…"` before the closing brace — or fill an empty object.
  const inner = canonical.slice(0, -1); // drop trailing '}'
  const sep = canonical === "{}" ? "" : ",";
  const line = `${inner}${sep}"entry_hash":${encodeJsonString(entryHash)}}`;
  return { line, entryHash };
}

/** Recompute an entry's self-hash the way `verify` does: drop entry_hash, canonicalize
 * (sorted, compact — jq -cjS), sha256. Used by TS `verify` and provable to equal the
 * `entryHash` that `buildEntryLine` stamped. */
export function recomputeEntryHash(parsed: { [key: string]: JsonValue }): string {
  const { entry_hash: _drop, ...rest } = parsed;
  void _drop;
  return sha256Hex(canonicalStringify(rest));
}

/** Hash a stored line as the chain does: bash `_line_hash` strips newlines then sha256.
 * A canonical line never contains a raw newline, so this is sha256 of the line as
 * stored (without its terminating newline). */
export function lineHash(line: string): string {
  return sha256Hex(line.replace(/\n/g, ""));
}
