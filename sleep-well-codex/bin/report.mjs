#!/usr/bin/env node
// 从磁盘重建 ~/sleep-well/codex/morning-report.md。**不依赖任何 AI 会话** ——
// 即便整夜两侧 AI 全挂，早报照样生成（这正是 shell 编排器相对 AI 编排器的价值）。
//
// 布局说明: Codex 侧整体收在 ~/sleep-well/codex/ 下，使 lib/report.mjs 的
// `stateDir = join(home,"state")` 假设成立 —— 那个文件因此可与 sleep-well 保持一致，
// 只有恢复提示语一处参数化。
import { buildReport } from "../lib/report.mjs";
import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const root = process.env.SLEEP_WELL_ROOT || join(process.env.HOME, "sleep-well");
const home = join(root, "codex");
mkdirSync(home, { recursive: true });
const md = buildReport({
  home,
  nowEpoch: Math.floor(Date.now() / 1000),
  stopPath: join(root, "STOP"),   // 编排器监听 root/STOP，不是 root/codex/STOP
  recoveryHint: "无需手动恢复——launchd 每 5 分钟会自动重试并从磁盘状态续跑；" +
                "若要停止请 touch ~/sleep-well/STOP",
});
const out = join(home, "morning-report.md");
writeFileSync(out, md);
console.log(out);
