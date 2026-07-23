/**
 * Shared test helpers.
 *
 * Plain-script style like the spike — no test-framework dependency. Every test is
 * offline: spawning `opencode serve` is free and allowed, but NO model is called.
 */

import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const repoRoot = path.resolve(__dirname, "..");
export const tsxBin = path.join(repoRoot, "node_modules", ".bin", "tsx");
export const serverEntry = path.join(repoRoot, "src", "server.ts");

/** A single test file's pass/fail accounting. */
export class Checker {
  failures = 0;
  passes = 0;
  check(condition: boolean, message: string): void {
    if (condition) {
      this.passes += 1;
      console.log(`  PASS: ${message}`);
    } else {
      this.failures += 1;
      console.error(`  FAIL: ${message}`);
    }
  }
}

export function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

/** True if a pid exists (EPERM counts as "exists but not ours"). */
export function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

/** Poll until `fn()` is true or the deadline passes. Returns the final value. */
export async function waitFor(
  fn: () => boolean,
  timeoutMs: number,
  pollMs = 100,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (fn()) return true;
    if (Date.now() >= deadline) return fn();
    await sleep(pollMs);
  }
}

/** Reject if `p` doesn't settle within `ms` — keeps a stuck spawn from hanging CI. */
export function withTimeout<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
    p.then(
      (v) => {
        clearTimeout(t);
        resolve(v);
      },
      (e) => {
        clearTimeout(t);
        reject(e);
      },
    );
  });
}
