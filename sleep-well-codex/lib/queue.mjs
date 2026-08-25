// lib/queue.mjs
// Parse queue.md: each "## Title" starts a task block. Lines "- key: value"
// are fields; remaining non-field, non-heading text is the prompt.
import { expandHome } from "./config.mjs";

const META_KEYS = new Set(["id", "repo", "priority", "type", "files", "team"]);

export function parseQueue(md) {
  const blocks = [];
  let cur = null;
  for (const line of md.split("\n")) {
    const h = line.match(/^##\s+(.+?)\s*$/);
    if (h) {
      if (cur) blocks.push(cur);
      cur = { title: h[1], fields: {}, body: [] };
      continue;
    }
    if (!cur) continue; // skip preamble before first ##
    // ⚠️ `(.+?)` 要求至少一个字符，于是 `- priority:` 这种**空值**根本不进 fields，
    //    校验被整个跳过、静默用默认值，那一行还会混进 prompt（Codex R16 #3）。
    //    改为允许空值被捕获，交给下面的校验拒绝——手写 Markdown 时漏填是最常见的错。
    const f = line.match(/^-\s+(\w+):\s*(.*?)\s*$/);
    if (f && META_KEYS.has(f[1])) cur.fields[f[1]] = f[2];
    else if (line.trim() !== "") cur.body.push(line.replace(/^>\s?/, ""));
  }
  if (cur) blocks.push(cur);
  // 重复 id 会让 state 里出现两条同 id 任务，advance/find 只作用于第一条，
  // 第二条永远停在 pending → 主循环反复选中它（Codex R2 #16）。
  const seen = new Set();
  for (const b of blocks) {
    const id = b.fields && b.fields.id;
    if (!id) continue;
    if (seen.has(id)) throw new Error(`队列中存在重复的任务 id: ${id}`);
    seen.add(id);
  }

  const tasks = blocks.map((b) => {
    if (!b.fields.id) throw new Error(`queue task "${b.title}" is missing id`);
    // id 会被拼进文件路径（编排器用 `$LOG_DIR/${id}-*.out` 与 `$LOG_DIR/${id}.md`），
    // `../` 之类会写到 logs 目录之外。
    // ⚠️ R15 我的处置是「限定 id 只能是 A-Za-z0-9._-」——**那是过度纠正**（Codex R16 #2）:
    //    queue.md 是与 Claude 侧共享的、用户手写的文件，里面完全可能有中文或含空格的 id。
    //    整个队列会因此被拒绝解析 → init 失败 → 落 TERMINATED + 卸载 launchd，
    //    一次升级就静默停掉一套本来正常的安装。
    //    正解是**保留 id 原样，只对派生的文件名做编码**（见 orchestrator 的 safe_id）。
    //    这里只拦真正危险的那两类: 路径分隔符与 `..`。
    // ⚠️ 这里的判据我写错过两次，两次都是「看起来管了、实际没管」:
    //   R15: 限定 `A-Za-z0-9._-` —— 过度纠正，含中文/空格 id 的既有队列整队被拒（R16 #2）
    //   R16: `id.split(/[^A-Za-z0-9]/).includes("..")` —— **永远为 false**
    //        （按非字母数字切分后 `..` 本身被切成空串），只有 id 恰好等于 `..` 才被拦，
    //        而 SKILL.md 却写着「拒绝所有含 `..` 的 id」（R17 #4 / 自查 S-1）。
    // 现在按 Codex R17 推荐的方案 B: **显示 id 与文件名彻底分离**——
    //   · 这里只拒绝「shell/文件系统层面无法如实往返」的字符
    //   · `..` 不再由 id 承担路径安全职责（`a..b` 是合法名字），
    //     安全性由 orchestrator 的 safe_id 保证（非安全字节全部编码 + 强制 t_ 前缀 + 哈希失败关闭）
    if (/[/\\]/.test(b.fields.id)) {
      throw new Error(`任务 id 不能包含路径分隔符，收到: ${JSON.stringify(b.fields.id)}`);
    }
    // NUL 与其它控制字符经 shell 命令替换会被静默丢弃（Codex R17 #3）:
    // 含 NUL 的 id 在每一次 advance/get-field/set-field 都会变形，找不到真正的状态条目，
    // 任务永远推不动而编排器会反复重试它。
    // ⚠️ 只覆盖 C0 与 DEL 不够（Codex R18 #4）: U+0085、U+009B 等 **C1** 控制字符
    //    同样会被接受，而原始 id 会直接写进日志——U+009B 是 CSI，能改变终端显示、
    //    隐藏或伪造诊断内容。用 Unicode `Cc` 类覆盖全部控制字符。
    if (/\p{Cc}/u.test(b.fields.id)) {
      throw new Error(`任务 id 含控制字符（经 shell 会被丢弃，导致任务永远推不动），收到: ${JSON.stringify(b.fields.id)}`);
    }
    // priority 写错会变成 NaN，而 NaN 参与比较全为 false → 排序结果不可预测且无提示
    // （R15 自查 Q-2）。宁可报错，也不要静默乱序。
    if (b.fields.repo !== undefined && b.fields.repo.trim() === "") {
      throw new Error(`任务 ${b.fields.id} 的 repo 为空`);
    }
    if (b.fields.priority !== undefined && !/^-?\d+$/.test(b.fields.priority.trim())) {
      throw new Error(`任务 ${b.fields.id} 的 priority 不是整数: ${JSON.stringify(b.fields.priority)}`);
    }
    if (b.fields.files !== undefined && !/^-?\d+$/.test(b.fields.files.trim())) {
      throw new Error(`任务 ${b.fields.id} 的 files 不是整数: ${JSON.stringify(b.fields.files)}`);
    }
    return {
      id: b.fields.id,
      title: b.title,
      repo: expandHome(b.fields.repo || ""),
      priority: b.fields.priority ? Number(b.fields.priority) : 100,
      type: b.fields.type || "task",
      files: b.fields.files ? Number(b.fields.files) : undefined,
      team: b.fields.team === "true" ? true : b.fields.team === "false" ? false : undefined,
      prompt: b.body.join("\n").trim(),
      status: "pending",
      reviewRounds: 0,
      reviewRotations: 0,
      findingsHistory: [],
    };
  });
  tasks.sort((a, b) => a.priority - b.priority);
  return tasks;
}
