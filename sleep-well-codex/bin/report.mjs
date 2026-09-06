#!/usr/bin/env node
// 从磁盘重建 ~/sleep-well/codex/morning-report.md。**不依赖任何 AI 会话** ——
// 即便整夜两侧 AI 全挂，早报照样生成（这正是 shell 编排器相对 AI 编排器的价值）。
//
// 布局说明: Codex 侧整体收在 ~/sleep-well/codex/ 下，使 lib/report.mjs 的
// `stateDir = join(home,"state")` 假设成立 —— 那个文件因此可与 sleep-well 保持一致，
// 只有恢复提示语一处参数化。
import { buildReport } from "../lib/report.mjs";
import { chmodSync, writeFileSync, mkdirSync, realpathSync } from "node:fs";
import { isAbsolute, join } from "node:path";

process.umask(0o077);
const configuredRoot = process.env.SLEEP_WELL_ROOT || join(process.env.HOME, "sleep-well");
if (!isAbsolute(configuredRoot)) throw new Error("SLEEP_WELL_ROOT must be an absolute path");
mkdirSync(configuredRoot, { recursive: true, mode: 0o700 });
const root = realpathSync(configuredRoot);
const accountHome = realpathSync(process.env.HOME);
if (root === "/" || root === accountHome) throw new Error("SLEEP_WELL_ROOT must not be / or the account HOME");
const home = join(root, "codex");
chmodSync(root, 0o700);
mkdirSync(home, { recursive: true, mode: 0o700 });
chmodSync(home, 0o700);
const md = buildReport({
  home,
  nowEpoch: Math.floor(Date.now() / 1000),
  stopPath: join(root, "STOP"),   // 编排器监听 root/STOP，不是 root/codex/STOP
  commitPrefix: "sleep-well-codex:",
  backupDir: join(home, "backups"),
  recoveryHint: "无需手动恢复——launchd 每 5 分钟会自动重试并从磁盘状态续跑；" +
                "若要停止请 touch ~/sleep-well/STOP",
});
const out = join(home, "morning-report.md");
writeFileSync(out, md, { mode: 0o600 });
chmodSync(out, 0o600);
console.log(out);
