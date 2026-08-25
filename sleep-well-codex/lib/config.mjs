// lib/config.mjs
import { homedir } from "node:os";
import { readFileSync } from "node:fs";
import { join } from "node:path";

export const DEFAULTS = {
  morning_hour: "07:00",
  review_rounds_rotate_at: 10,
  review_rotations_max: 2,
  review_stall_rounds: 2,
  codex_degrade_after_hours: 10,
  codex_recheck_after_weekly_reset: false,
  team_route_min_files: 3,
  team_autoproceed_confidence: 0.85,
  team_max_delegations_per_night: 4,
  discovery_k_per_cycle: 3,
  discovery_repo: "~/Projects/example-repo",
  discovery_tiers_auto: [1, 2, 3],
  discovery_tiers_propose: [4],
  // ⚠️ 本技能不用这个默认值: Codex 侧的备份在 ~/sleep-well/codex/backups（状态独立的设计裁定），
  // 由 orchestrator.sh 显式传给 cli.mjs backup-file。留在这里只为与 sleep-well 保持同源。
  backup_dir: "~/sleep-well/backups",
  backup_nongit_docs: true,
  backup_cleanup: "on-confirm",
  push_enabled: true,
};

export function expandHome(p) {
  if (typeof p === "string" && p.startsWith("~")) return homedir() + p.slice(1);
  return p;
}

export function mergeConfig(userCfg = {}) {
  return { ...DEFAULTS, ...userCfg };
}

// ⚠️ 默认路径指向 **Claude 侧** 的 ~/sleep-well/config.json，而本技能的配置在
// ~/sleep-well/codex/config.json。现有调用点都显式传路径（lib/cli.mjs），所以不是活缺陷，
// 但不带参数调用会静默读到另一侧的配置——改这里之前先看清调用方（自查 T-5）。
export function loadConfig(path = join(homedir(), "sleep-well", "config.json")) {
  let userCfg = {};
  try {
    userCfg = JSON.parse(readFileSync(path, "utf-8"));
  } catch (e) {
    if (e.code !== "ENOENT") throw e; // missing file => defaults; malformed => surface
  }
  const merged = mergeConfig(userCfg);
  for (const k of ["backup_dir", "discovery_repo"]) {
    if (typeof merged[k] === "string") merged[k] = expandHome(merged[k]);
  }
  return merged;
}
