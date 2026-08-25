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
  return readFileSync(path, "utf-8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
}
