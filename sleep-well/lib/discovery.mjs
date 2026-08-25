// lib/discovery.mjs — pure idle-discovery helpers + tried.log dedupe store.
import { createHash } from "node:crypto";
import { appendFileSync, readFileSync, existsSync } from "node:fs";

export function triedKey(c) {
  return createHash("sha1")
    .update(`${c.source || ""}\0${c.repo || ""}\0${c.path || ""}\0${c.text || ""}`)
    .digest("hex").slice(0, 16);
}

// parse `grep -rn "TODO|FIXME|XXX|HACK" ...` lines "path:line:content" into candidates.
export function parseTodos(grepOutput, repo) {
  const out = [];
  for (const line of String(grepOutput).split("\n")) {
    const m = line.match(/^(.+?):(\d+):(.*)$/);
    if (!m) continue;
    out.push({ source: "tier2-todo", repo, path: m[1], line: Number(m[2]), text: m[3].trim() });
  }
  return out;
}

export function dedupe(candidates, triedSet) {
  return candidates.filter((c) => !triedSet.has(triedKey(c)));
}

// tiers: ordered [{tier, items:[...]}]. Flatten in order, take up to k.
export function pickCandidates(tiers, k) {
  const picked = [];
  for (const { items } of tiers) {
    for (const it of items || []) {
      if (picked.length >= k) return picked;
      picked.push(it);
    }
  }
  return picked;
}

export function tierMode(tier, cfg) {
  if ((cfg.discovery_tiers_auto || []).includes(tier)) return "auto";
  if ((cfg.discovery_tiers_propose || []).includes(tier)) return "propose";
  return "off";
}

export function loadTried(path) {
  if (!existsSync(path)) return new Set();
  return new Set(readFileSync(path, "utf8").trim().split("\n").filter(Boolean));
}

export function markTried(path, candidate) {
  appendFileSync(path, triedKey(candidate) + "\n");
}
