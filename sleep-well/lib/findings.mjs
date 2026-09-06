// lib/findings.mjs
import { appendFileSync, readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";

export function findingKey({ repo = "", file = "", line = "", issue = "" }) {
  return createHash("sha1").update(`${repo}\0${file}\0${line}\0${issue}`).digest("hex").slice(0, 16);
}

export function appendFinding(path, finding) {
  const rec = { ...finding, key: findingKey(finding) };
  appendFileSync(path, JSON.stringify(rec) + "\n");
  return rec;
}

export function readFindings(path) {
  if (!existsSync(path)) return [];
  const findings = [];
  for (const raw of readFileSync(path, "utf-8").split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    try {
      findings.push(JSON.parse(line));
    } catch {
      // JSONL is append-only and a killed writer may leave one partial line.
      // Preserve the remaining valid findings instead of disabling discovery.
    }
  }
  return findings;
}
