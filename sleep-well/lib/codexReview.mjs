// lib/codexReview.mjs
//
// NOTE on real codex exec review --json output (confirmed via probe 2026-06-16):
//   - codex does NOT support a -C flag; the caller must pass repo via cwd.
//   - JSONL records use type:"item.completed" with item.type:"agent_message" and item.text
//     for the prose findings summary. There is NO structured findings[] array.
//
import { execFileSync } from "node:child_process";

const CODEX = process.env.SLEEP_WELL_CODEX || "codex"; // resolver wrapper on PATH

export function reviewTimeoutMs(raw = process.env.SLEEP_WELL_AI_TIMEOUT) {
  if (raw == null || raw === "") return 1_800_000;
  const text = String(raw);
  if (!/^\d+$/.test(text)) throw new Error("SLEEP_WELL_AI_TIMEOUT must be an integer number of seconds");
  const seconds = Number(text);
  if (!Number.isSafeInteger(seconds) || seconds < 1 || seconds > 86_400) {
    throw new Error("SLEEP_WELL_AI_TIMEOUT must be between 1 and 86400 seconds");
  }
  return seconds * 1000;
}

export function reviewExecOptions(repo, timeoutRaw = process.env.SLEEP_WELL_AI_TIMEOUT) {
  return {
    encoding: "utf-8",
    cwd: repo,
    maxBuffer: 32 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
    timeout: reviewTimeoutMs(timeoutRaw),
  };
}

export function buildReviewArgs({ scope = "uncommitted", base }) {
  const args = ["exec", "review"];
  if (scope === "base") args.push("--base", base);
  else args.push("--uncommitted");
  args.push("--json");
  return args;
}

// Tolerant parser: codex --json emits JSONL.
//
// Two modes are supported:
//   1. Structured: any line carrying a `findings` array (last such line wins).
//      This matches the assumed schema in unit tests and any future codex version.
//   2. Prose fallback: real codex 0.133.x emits type:"item.completed" with
//      item.type:"agent_message" and item.text containing natural-language findings.
//      We collect all agent_message texts and expose them as agentText.
//
// Returns { count, findings, reviewed, agentText? }
//   count    — length of structured findings[] (0 when only prose output)
//   findings — structured finding objects ([] when only prose output)
//   reviewed — true only when at least one structured findings array (including
//              an explicit empty array) or non-empty agent_message was observed
//   agentText — concatenated agent_message text(s); present only when found
export function parseFindings(output) {
  const lines = String(output).trim().split("\n").filter(Boolean);
  let findings = [];
  let structuredSeen = false;
  const agentTexts = [];

  for (const line of lines) {
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }
    if (!obj) continue;

    // Structured findings array (assumed schema / future codex versions)
    if (Array.isArray(obj.findings)) {
      findings = obj.findings;
      structuredSeen = true;
    }

    // Real codex 0.133.x: agent_message text inside item.completed
    if (
      obj.type === "item.completed" &&
      obj.item &&
      obj.item.type === "agent_message" &&
      typeof obj.item.text === "string" &&
      obj.item.text.trim()
    ) {
      agentTexts.push(obj.item.text.trim());
    }
  }

  const result = {
    count: findings.length,
    findings,
    reviewed: structuredSeen || agentTexts.length > 0,
  };
  if (agentTexts.length > 0) result.agentText = agentTexts.join("\n\n");
  return result;
}

// Live call — integration, not unit-tested. repo is passed via cwd (codex review has no -C).
export function runReview({ repo, scope = "uncommitted", base }) {
  const out = execFileSync(CODEX, buildReviewArgs({ scope, base }), reviewExecOptions(repo));
  return parseFindings(out);
}
