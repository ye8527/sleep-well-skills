// lib/backup.mjs
import { copyFileSync, mkdirSync, appendFileSync, readFileSync, existsSync } from "node:fs";
import { basename, join } from "node:path";
import { createHash } from "node:crypto";

// runDate is injected by the caller (deterministic, no Date.now() here).
export function backupFile(original, { backupRoot, runDate, reason, stamp }) {
  const dir = join(backupRoot, runDate);
  mkdirSync(dir, { recursive: true });
  const tag = stamp || createHash("sha1").update(original).digest("hex").slice(0, 8);
  const backupPath = join(dir, `${basename(original)}.${tag}.bak`);
  if (!existsSync(backupPath)) {
    copyFileSync(original, backupPath);
    const entry = { original, backupPath, runDate, reason };
    appendFileSync(join(backupRoot, "backup-manifest.jsonl"), JSON.stringify(entry) + "\n");
    return entry;
  }
  return { original, backupPath, runDate, reason, skipped: true };
}

export function readManifest(backupRoot) {
  const p = join(backupRoot, "backup-manifest.jsonl");
  if (!existsSync(p)) return [];
  return readFileSync(p, "utf-8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
}
