// lib/claudeReview.mjs — 调 claude-handoff 做独立审查，解析其产物。
//
// 反向对照物: ~/.claude/skills/sleep-well/lib/codexReview.mjs（那边是 Claude 产出 → codex 审）。
//
// 与 codexReview 的关键差异:
//   该适配器输出结构化 findings 和机读计数；本模块不让模型重新估算条数。
//
// 失败关闭契约（继承自 claude-handoff）:
//   findings 文件存在且适配器退出码为 0，才可能表示该轮审查完整可信。
//   文件不存在或退出码非零时**绝不**当作「零 findings 通过」。

import { readFileSync, existsSync } from "node:fs";

// 解析 claude-handoff 的 stdout/stderr。纯函数，可单测。
// 返回 { ok, findingsFile, count, high, unavailable, reason }
//   ok=true 仅当拿到 findings 文件路径且条数可解析——任何存疑一律 ok=false。
export function parseReviewOutput(stdout = "", stderr = "", code = 0) {
  const out = String(stdout);
  const err = String(stderr);

  // 不可用信号优先: claude-handoff 打印 `CLAUDE_UNAVAILABLE (quota|auth|other)`
  const un = err.match(/CLAUDE_UNAVAILABLE\s*\(([a-z]+)\)/);
  if (un) {
    return { ok: false, unavailable: un[1], reason: `claude 不可用: ${un[1]}` };
  }

  const fm = out.match(/^FINDINGS_FILE=(.+)$/m);
  if (!fm) {
    return {
      ok: false,
      unavailable: null,
      reason: `未产出 findings 文件（退出码 ${code}）——按失败关闭契约，不得视为零 findings`,
    };
  }
  const findingsFile = fm[1].trim();

  // A file published before an adapter crash is diagnostic material, not a
  // completed review. Preserve its path in the result but reject every nonzero
  // exit before reading or trusting its contents.
  if (code !== 0) {
    return {
      ok: false,
      unavailable: null,
      findingsFile,
      reason: `适配器以退出码 ${code} 结束——不完整审查不得视为可信结果`,
    };
  }

  // claude-handoff 的契约是「findings **文件**存在 ⟺ 该轮完整可信」。stdout 只是回显——
  // 文件发布失败/被删/不可读时若退回读 stdout，一个「0 条」摘要就能让任务直接通过，
  // 正好违反该契约（Codex R1 #3）。故文件不存在即失败关闭，绝不回退。
  if (!existsSync(findingsFile)) {
    return {
      ok: false, unavailable: null, findingsFile,
      reason: `stdout 声明了 findings 文件但它不存在: ${findingsFile}——契约要求文件存在才可信`,
    };
  }
  const body = readFileSync(findingsFile, "utf8");
  const cm = body.match(/^-\s*findings 条数:\s*(\d+)/m);
  const hm = body.match(/^-\s*高严重度:\s*(\d+)/m);
  const count = cm ? Number(cm[1]) : null;
  const high = hm ? Number(hm[1]) : null;
  if (count === null) {
    return {
      ok: false,
      unavailable: null,
      findingsFile,
      reason: "findings 文件存在但条数不可解析——不得猜测条数",
    };
  }
  return { ok: true, unavailable: null, findingsFile, count, high: high ?? 0, reason: "" };
}

// 从 findings 文件抽取逐条 finding，供 findings.jsonl 记录。
// claude-handoff 的格式: `### #N [严重度] 标题` + `- 位置: \`file\` location`
// 严重度映射: 高 → needs-human（要人判断的风险），中/低 → auto（可自修）。
// 这个映射是保守的: 宁可把可自修的标成 needs-human，也不要让高危被自动改掉。
export function extractFindings(findingsFileText) {
  const out = [];
  const lines = String(findingsFileText).split("\n");
  for (let i = 0; i < lines.length; i++) {
    const h = lines[i].match(/^###\s+#(\d+)\s+\[(高|中|低)\]\s+(.+?)\s*$/);
    if (!h) continue;
    let file = "";
    let location = "";
    for (let j = i + 1; j < Math.min(i + 6, lines.length); j++) {
      const loc = lines[j].match(/^-\s*位置:\s*`([^`]*)`\s*(.*)$/);
      if (loc) {
        file = loc[1];
        location = loc[2].trim();
        break;
      }
    }
    out.push({
      n: Number(h[1]),
      severity: h[2],
      title: h[3],
      file,
      location,
      kind: h[2] === "高" ? "needs-human" : "auto",
    });
  }
  return out;
}

// 断言「处理状态骨架条目数 == 元信息头声明的条数」。
// claude-handoff 由脚本预生成骨架，两者本应恒等；不等说明文件被改坏或被截断。
export function verifyFindingsIntegrity(findingsFileText, declaredCount) {
  const skeleton = (String(findingsFileText).match(/^-\s*\[ \]\s*#\d+/gm) || []).length;
  return {
    ok: skeleton === declaredCount,
    skeleton,
    reason:
      skeleton === declaredCount
        ? ""
        : `处理状态骨架 ${skeleton} 条 ≠ 声明的 ${declaredCount} 条，findings 文件可疑`,
  };
}
