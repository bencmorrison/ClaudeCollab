/**
 * Model policy port (PLAN.md M4; CONTRACT.md area A, C1–C7).
 *
 * The oracle is `collab/ask.sh` — its `_has_rules`, `policy_tier`, and the policy
 * resolution/enforcement block. This module reproduces those semantics EXACTLY, so a
 * TS caller (the M5+ MCP tools, `doctor`) reaches the same deny/ask/allow verdict the
 * bash wrapper does for every model id. Where this file and the bash disagree, the
 * bash wins — hence the flagship oracle cross-check in `test/policy.test.ts`, which
 * drives the real `ask.sh --dry-run` over a corpus and asserts agreement per case.
 *
 * Two invariants worth stating up front because they drove the shape of the code:
 *   1. FAIL-CLOSED. A resolved-but-unreadable policy file, or any malformed active
 *      line, resolves to `deny` with a loud reason — never a silent `allow`. This
 *      closed two real fail-opens (PLAN.md ~line 91).
 *   2. BASH `case`-GLOB semantics, not minimatch. `*` and `?` cross `/`; there is no
 *      pathname/dotfile special-casing (a `case` statement is a pure pattern match).
 *      `bashGlobMatch` replicates `*`, `?`, `[...]` (ranges, `!`/`^` negation, POSIX
 *      classes) as bash resolves them — see the converter below.
 */

import { readFileSync, statSync } from "node:fs";
import path from "node:path";

export type PolicyTier = "allow" | "ask" | "deny";
/** Which of the three resolution slots supplied the active policy file (C1). */
export type PolicySource = "env" | "local" | "committed";

export interface PolicyDecision {
  tier: PolicyTier;
  /** The file that was resolved and consulted (doctor + M5 diagnostics need it). */
  policyFile: string;
  source: PolicySource;
  /** Set only on a fail-closed deny: the loud reason to surface to the user. */
  reason?: string;
}

/* ---------------------------------------------------------------------------
 * Bash `case` glob matching.
 *
 * Reproduces the pattern matching bash performs in `case "$model" in $pat)`:
 *   *        any string, including empty AND including `/` (no pathname rules)
 *   ?        exactly one character, including `/`
 *   [set]    a bracket expression: ranges `a-z`, negation `[!...]`/`[^...]`,
 *            POSIX classes `[:alpha:]`, a leading `]` as a literal, and an
 *            UNTERMINATED `[` falls back to a literal `[` (bash's behaviour).
 *   \x       backslash escapes the next character to a literal.
 * extglob (`@(...)`, `+(...)`, …) is OFF by default in bash and unused by policy
 * files, so it is intentionally not implemented.
 *
 * We translate to a JS RegExp anchored `^…$`. `*`→`[\s\S]*` and `?`→`[\s\S]` so
 * they cross `/` and newlines the way `case` does.
 *
 * PARITY SCOPE: exact bash-`case` parity is proven for ASCII patterns and ids — the
 * realistic domain, since provider/model ids are ASCII. It is NOT claimed for non-ASCII
 * input: JS `?`/`[\s\S]` count UTF-16 code units (astral characters differ from bash's
 * byte/char counting) and POSIX classes here are ASCII-only where bash's are
 * locale-aware. An invalid bracket range never matches rather than throwing (see the
 * RegExp construction below) — that IS parity.
 * --------------------------------------------------------------------------- */

/** Escape one char for use OUTSIDE a regex character class. */
function escapeRegexLiteral(ch: string): string {
  return /[.*+?^${}()|[\]\\]/.test(ch) ? "\\" + ch : ch;
}

/** Escape one char for use INSIDE a regex character class. Only `\` and `]` are
 * special there; `-`, `^`, `[`, `.` etc. must pass through so bash ranges/literals
 * (`[a-z]`, `[a-]`, `[a^]`) survive translation unchanged. */
function escapeRegexClassLiteral(ch: string): string {
  return ch === "\\" || ch === "]" ? "\\" + ch : ch;
}

/** POSIX character-class name → JS char-class body. Unknown names contribute
 * nothing (best-effort; policy files do not use these in practice). */
function posixClassBody(name: string): string {
  switch (name) {
    case "alpha": return "A-Za-z";
    case "digit": return "0-9";
    case "alnum": return "A-Za-z0-9";
    case "upper": return "A-Z";
    case "lower": return "a-z";
    case "space": return "\\t\\n\\r\\f\\v ";
    case "blank": return "\\t ";
    case "punct": return "!-/:-@\\[-`{-~";
    case "xdigit": return "0-9A-Fa-f";
    default: return "";
  }
}

export function bashGlobToRegExp(pattern: string): RegExp {
  let re = "";
  let i = 0;
  const n = pattern.length;
  while (i < n) {
    const c = pattern[i];
    if (c === "\\") {
      // Escape: the next char is literal. A trailing lone backslash is itself a
      // literal backslash (bash matches a literal `\`).
      const next = pattern[i + 1];
      if (next === undefined) { re += "\\\\"; i += 1; }
      else { re += escapeRegexLiteral(next); i += 2; }
      continue;
    }
    if (c === "*") { re += "[\\s\\S]*"; i += 1; continue; }
    if (c === "?") { re += "[\\s\\S]"; i += 1; continue; }
    if (c === "[") {
      // Attempt to parse a bracket expression; on failure fall back to literal `[`.
      let j = i + 1;
      let negate = false;
      if (pattern[j] === "!" || pattern[j] === "^") { negate = true; j += 1; }
      let body = "";
      let first = true; // a `]` in the first content position is a literal, not a close
      let closed = false;
      while (j < n) {
        const cc = pattern[j];
        if (cc === "]" && !first) { closed = true; break; }
        first = false;
        if (cc === "[" && pattern[j + 1] === ":") {
          const end = pattern.indexOf(":]", j + 2);
          if (end !== -1) {
            body += posixClassBody(pattern.slice(j + 2, end));
            j = end + 2;
            continue;
          }
        }
        body += escapeRegexClassLiteral(cc);
        j += 1;
      }
      if (closed) {
        re += "[" + (negate ? "^" : "") + body + "]";
        i = j + 1;
        continue;
      }
      // Unterminated bracket → literal `[` (bash).
      re += "\\[";
      i += 1;
      continue;
    }
    re += escapeRegexLiteral(c);
    i += 1;
  }
  try {
    return new RegExp("^" + re + "$");
  } catch {
    // A reverse bracket range (`[9-0]`, `[c-a]`, `[z-a]`) is a valid bash glob that
    // simply never matches — bash falls through to the next rule (verified live). JS
    // `new RegExp` instead THROWS RangeError ("Range out of order") on the same input.
    // Unguarded, that RangeError would propagate out of tierFromContents/policyTier and
    // the security gate would return NEITHER allow NOR deny — worse than a wrong
    // verdict. Substitute a pattern that matches nothing, so this one rule matches
    // nothing (bash parity) while every OTHER rule in the file still evaluates.
    return /(?!)/;
  }
}

export function bashGlobMatch(pattern: string, str: string): boolean {
  return bashGlobToRegExp(pattern).test(str);
}

/* ---------------------------------------------------------------------------
 * _has_rules — does this file carry ≥1 complete tier+pattern rule? (C1/C2)
 *
 * Oracle awk (ask.sh):
 *     /^[[:space:]]*(#|$)/            { next }
 *     $1 ~ /^(allow|ask|deny)$/ && NF >= 2 && $2 !~ /^#/ { found=1; exit }
 * i.e. skip blank/comment lines; a line is a rule iff its first whitespace field is
 * exactly allow|ask|deny, there are ≥2 fields, and the second field is not a comment.
 * A bare `deny` (no pattern) is NOT a rule, so it cannot shadow the committed policy.
 * --------------------------------------------------------------------------- */
export function hasRules(contents: string): boolean {
  for (const line of contents.split("\n")) {
    // `^[[:space:]]*(#|$)` — blank/whitespace-only or a comment line.
    if (/^[ \t]*(#|$)/.test(line)) continue;
    // awk default field split: runs of whitespace, leading/trailing trimmed.
    const fields = line.trim().split(/[ \t]+/);
    if (
      (fields[0] === "allow" || fields[0] === "ask" || fields[0] === "deny") &&
      fields.length >= 2 &&
      !fields[1].startsWith("#")
    ) {
      return true;
    }
  }
  return false;
}

/* ---------------------------------------------------------------------------
 * Line splitting for policy_tier: `read -r tier pat rest`.
 *
 * bash `read` with three names splits on IFS whitespace (space/tab; newline can't
 * occur within a line): field 1 = tier, field 2 = pat, and `rest` = everything after,
 * with the inter-field whitespace run and any TRAILING whitespace stripped but the
 * internal whitespace of `rest` preserved. Verified live against `read -r`.
 * --------------------------------------------------------------------------- */
function splitRule(line: string): { tier: string; pat: string; rest: string } {
  const s = line.replace(/^[ \t]+/, "");
  const w1 = s.search(/[ \t]/);
  if (w1 === -1) return { tier: s, pat: "", rest: "" };
  const tier = s.slice(0, w1);
  const afterTier = s.slice(w1).replace(/^[ \t]+/, "");
  const w2 = afterTier.search(/[ \t]/);
  if (w2 === -1) return { tier, pat: afterTier, rest: "" };
  const pat = afterTier.slice(0, w2);
  const rest = afterTier.slice(w2).replace(/^[ \t]+/, "").replace(/[ \t]+$/, "");
  return { tier, pat, rest };
}

/**
 * Pure policy evaluation over already-read file contents (C3–C6).
 *
 * First matching glob wins, top to bottom; default is `allow`. The WHOLE file is
 * parsed even when `model` is empty or already matched, so a malformed active line
 * anywhere fails the file closed (`deny`) — matching the bash, which validates every
 * line before returning. `fileLabel` only shapes the reason string.
 *
 * Note on the "no trailing newline" scar (C6): `contents.split("\n")` yields the final
 * line whether or not the file ends in `\n` (a trailing `\n` just adds an empty final
 * element, which is skipped as a blank line) — so the last rule is never dropped, the
 * exact bug the bash `|| [ -n "$line" ]` guards.
 */
export function tierFromContents(
  contents: string,
  model: string,
  fileLabel = "policy",
): { tier: PolicyTier; reason?: string } {
  let matched: PolicyTier | "" = "";
  const lines = contents.split("\n");
  for (let idx = 0; idx < lines.length; idx += 1) {
    const lineNo = idx + 1;
    const { tier, pat, rest } = splitRule(lines[idx]);
    // Skip blanks and comment lines (tier empty or starting with `#`).
    if (tier === "" || tier.startsWith("#")) continue;
    if (tier === "allow" || tier === "ask" || tier === "deny") {
      // Malformed: no pattern, a pattern that is actually a comment, or trailing
      // non-comment tokens.
      if (pat === "" || pat.startsWith("#") || (rest !== "" && !rest.startsWith("#"))) {
        return {
          tier: "deny",
          reason: `malformed model policy rule at ${fileLabel}:${lineNo}: expected '<allow|ask|deny> <glob-pattern> [# comment]' — refusing (fail-closed).`,
        };
      }
    } else {
      return {
        tier: "deny",
        reason: `malformed model policy rule at ${fileLabel}:${lineNo}: unknown tier '${tier}' — refusing (fail-closed).`,
      };
    }
    if (matched === "" && model !== "" && bashGlobMatch(pat, model)) {
      matched = tier;
    }
  }
  return { tier: matched === "" ? "allow" : matched };
}

/**
 * Policy file resolution (C1): `$GUILD_POLICY` if set, else a git-ignored
 * `models.policy.local` ONLY IF it carries ≥1 rule, else the committed `models.policy`.
 * `collabDir` is the directory the bash resolves via `dirname "$0"` (i.e. `modelguild/`).
 */
export function resolvePolicyFile(
  collabDir: string,
  env: NodeJS.ProcessEnv = process.env,
): { file: string; source: PolicySource } {
  const override = env.GUILD_POLICY;
  if (override && override.length > 0) return { file: override, source: "env" };
  const local = path.join(collabDir, "models.policy.local");
  let localContents: string | undefined;
  try { localContents = readFileSync(local, "utf8"); } catch { localContents = undefined; }
  if (localContents !== undefined && hasRules(localContents)) {
    return { file: local, source: "local" };
  }
  return { file: path.join(collabDir, "models.policy"), source: "committed" };
}

/**
 * Full policy verdict for a model (C1–C7). Resolves the file, then:
 *   - no such regular file            → allow (policy only ever restricts)
 *   - exists but unreadable           → deny, loud reason (fail-closed, C5)
 *   - malformed active line           → deny, loud reason (fail-closed, C6)
 *   - first matching glob wins        → its tier (C3)
 *   - no match / empty model id       → allow (C4)
 *
 * TOCTOU divergence (deliberate, in the safe direction): if the file vanishes between
 * the `statSync` and the `readFileSync`, this returns DENY (the read throws → the
 * unreadable branch). Bash's `[ -r ]`-then-read race would instead fall through to
 * `echo allow` (fail-OPEN) on that same window. A rare, intentional non-parity: a
 * disappearing policy file fails closed here, open there. Stated so it is not read as a
 * bug.
 */
export function policyTier(
  model: string,
  opts: { collabDir: string; env?: NodeJS.ProcessEnv },
): PolicyDecision {
  const env = opts.env ?? process.env;
  const { file, source } = resolvePolicyFile(opts.collabDir, env);
  // `[ -f "$policy_file" ]` — a missing file or non-regular path (e.g. a directory)
  // means default-allow.
  let st;
  try { st = statSync(file); } catch { return { tier: "allow", policyFile: file, source }; }
  if (!st.isFile()) return { tier: "allow", policyFile: file, source };
  // `[ ! -r ]` — exists but unreadable ⇒ fail closed.
  let contents: string;
  try { contents = readFileSync(file, "utf8"); } catch {
    return {
      tier: "deny",
      policyFile: file,
      source,
      reason: `policy file '${file}' exists but is unreadable — refusing (fail-closed).`,
    };
  }
  const { tier, reason } = tierFromContents(contents, model, file);
  return { tier, reason, policyFile: file, source };
}
