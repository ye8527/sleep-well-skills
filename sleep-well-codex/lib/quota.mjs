// lib/quota.mjs — 双向额度/可用性判定。纯函数，无副作用，可单测。
//
// 改写自 sleep-well 的 lib/quota.mjs（那边只判 Codex 一侧，Claude 侧靠 claude-quotas MCP；
// shell 编排器调不到 MCP，故两侧都从进程输出判定）。
//
// 设计原则: **只从证据判定，不猜**。识别不出的一律归 other，由调用方按「不可用但原因不明」
// 处理（重试有限次后转 needs_human），绝不默认「大概是额度问题、等等就好」——那会让
// 一个真正的配置错误在夜里空转到天亮。

const QUOTA_RE = /rate[ _-]?limit|usage[ _-]?limit|quota|429|too many requests|exceeded|额度|上限/i;
// Authentication is the only classification that immediately halts the whole
// night. Use strong CLI failure phrases, never ordinary task vocabulary such
// as bare "oauth", "credential", "authenticate", "401", or "unauthorized".
const AUTH_RE = /not logged in|please run \/login|(?:login|authentication) required|invalid (?:authentication )?credentials?|401\s+unauthorized|unauthorized\s*\(401\)/i;
// 瞬时拥塞: 值得退避重试，与额度耗尽不同（后者要等窗口重置，重试无用）
const TRANSIENT_RE = /overload|529|50[234]|timeout|timed out|ECONN|ENOTFOUND|EAI_AGAIN|socket hang up|混雑/i;

// $1=进程输出（stdout+stderr 合并）$2=退出码 $3='claude'|'codex'
// 返回 { side, kind }，kind ∈ quota | auth | transient | other | ok
export function classifyOutcome(output, code, side) {
  const s = String(output || "");
  // 124 is generated locally by run_with_timeout. The captured file may be a
  // truncated agent transcript containing auth-related task vocabulary; it is
  // not evidence that either remote account lost authentication.
  if (code === 124) return { side, kind: "transient" };
  // ⚠️ 宽泛文本正则**只在失败输出上**使用: 一个成功的任务如果本身就在实现额度处理、
  // 或在描述 HTTP 429，正文里必然出现 quota/429/exceeded 等词，按文本判会被误判成
  // 不可用而错误退避、甚至按认证失效 halt（Codex R1 #17）。退出码 0 一律视为成功，
  // 唯一例外是 claude-handoff 自报的结构化信号 CLAUDE_UNAVAILABLE。
  const selfReported = side === "claude"
    ? s.match(/CLAUDE_UNAVAILABLE\s*\(([a-z]+)\)/)
    : null;
  if (code === 0 && !selfReported) return { side, kind: "ok" };

  // claude-handoff 自己会打 CLAUDE_UNAVAILABLE (kind)，优先采信它的结构化判定
  if (selfReported && side === "claude") {
    const k = selfReported[1];
    return { side, kind: k === "quota" || k === "auth" ? k : "other" };
  }

  if (AUTH_RE.test(s)) return { side, kind: "auth" };
  if (QUOTA_RE.test(s)) return { side, kind: "quota" };
  if (TRANSIENT_RE.test(s)) return { side, kind: "transient" };
  return { side, kind: code === 0 ? "ok" : "other" };
}

// 根据两侧状态决定这一跳做什么。纯函数。
//   claudeKind / codexKind ∈ ok | quota | auth | transient | other
// 返回 { action, reason }
//   action ∈ work | defer-review | fix-only | idle | halt
//     work         —— 正常: 实现 + 审查
//     defer-review —— Claude 不可用但 Codex 可用: 继续实现，把审查挂起
//     fix-only     —— Codex 不可用但 Claude 可用: 不取新任务，只处理已有 findings 的修复
//     idle         —— 两侧都暂时不可用: 本跳什么都不做，下跳再探（launchd 每 5 分钟自然重试）
//     halt         —— 需要人介入（认证失效等重试无用的情形）: 出早报、推送、停止
export function decideHop(claudeKind, codexKind) {
  if (codexKind === "auth") return { action: "halt", reason: "codex 认证失效，重试无用，需人工 codex login" };
  if (claudeKind === "auth") return { action: "halt", reason: "claude 认证失效，重试无用，需人工 claude login" };

  const codexDown = codexKind !== "ok";
  const claudeDown = claudeKind !== "ok";

  if (!codexDown && !claudeDown) return { action: "work", reason: "两侧可用" };
  if (!codexDown && claudeDown) return { action: "defer-review", reason: `claude ${claudeKind}，挂起审查继续实现` };
  if (codexDown && !claudeDown) return { action: "fix-only", reason: `codex ${codexKind}，只做已有 findings 的修复` };
  return { action: "idle", reason: `两侧均不可用（claude ${claudeKind} / codex ${codexKind}），下跳再探` };
}

// 退避: 瞬时拥塞时该等几跳（一跳=5 分钟）。耗尽后返回 giveUp。
// 与 sleep-well 的 backoff.mjs 同义，但单位是「跳」而非秒——launchd 心跳固定 5 分钟，
// 用跳数表达比算绝对唤醒时刻更不容易错（sleep-well 的 planRelay 要算 epoch，算错就睡过头）。
export function nextBackoffHops(attempt) {
  const schedule = [1, 2, 4, 8, 12, 12]; // 5m,10m,20m,40m,60m,60m ≈ 累计 3 小时
  if (attempt >= schedule.length) return { giveUp: true, hops: 0 };
  return { giveUp: false, hops: schedule[attempt] };
}
