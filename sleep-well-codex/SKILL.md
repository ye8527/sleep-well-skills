---
name: sleep-well-codex
description: Overnight night-shift orchestrator for Codex. Works ~/sleep-well/queue.md task-by-task — implement, Claude Code review via a compatible adapter, fix, re-review until zero findings (capped) — driven by a shell orchestrator under launchd, with disk-state relay, fail-closed quarantine of process-interrupted tasks, post-hoc guardrail verification, and optional ntfy.sh push. Triggers on sleep-well-codex, night shift, 夜班, overnight tasks, 通宵跑任务.
---

# sleep-well-codex — Codex 夜班编排器

## 作用与边界

用户离开电脑时，`bin/orchestrator.sh` 按 `~/sleep-well/queue.md` 逐项调用 Codex 实现、调用独立的 Claude 审查适配器审查未提交差异，并在零 findings 后创建本地 checkpoint 提交。进度、心跳、日志和早报都写入 `~/sleep-well/codex/`；可用性失败会按磁盘状态中继。若整个编排器进程异常终止，遗留的 implementing/reviewing/fixing 任务会转 `needs_human` 而不自动续跑，避免把终止窗口内未核验的仓库改动吸收为新护栏基线。

反向变体是 `~/.claude/skills/sleep-well/`。两者可以读取同一份队列，但状态文件互不相同，而且只有本变体获取 `~/sleep-well/NIGHT.lock`。**一次只能运行一个变体。**

Codex agent 通常不直接执行任务循环。编排器会以两个全新的无记忆会话调用它：

1. 实现者：任务 prompt + `prompts/implement.md`
2. 修复者：findings 摘要 + `prompts/fix.md`

这些 prompt 是会话内约束的权威来源。

## 启动与运维

启动前确认：

1. macOS 上已安装 Node.js 18+、Git、Codex CLI，以及符合 README 契约的可执行 Claude 审查适配器。默认路径是 `~/.codex/skills/claude-handoff/scripts/claude-code-review.sh`，也可用 `SLEEP_WELL_CLAUDE_REVIEW` 指定。
2. 目标仓库是干净的；`.review/` 审查产物除外，而且至少已有一个可用的 `HEAD` 提交作为 checkpoint/护栏基线。已有任务改动时编排器会拒绝开工，避免混入 checkpoint；尚无提交的仓库会把该任务如实转为 `needs_human`，不会误报护栏违规或阻断后续队列。
3. `queue.md` 是本夜要执行的当前队列。
4. 另一个 sleep-well 变体未在运行。

可选路径覆写：`SLEEP_WELL_CODEX` 指定 Codex 可执行文件（绝对路径或可由 PATH 解析的命令名）；`SLEEP_WELL_ROOT` 改变运行状态根目录，但必须是专用绝对路径，不能是 `/` 或账户 HOME 本身；`SLEEP_WELL_QUEUE` 只改变队列文件路径。launchd 使用时必须把这些变量显式写入其环境，不能依赖交互式 shell 配置。

launchd 的非交互环境不保证包含交互式 shell 的 PATH。编排器会在现有 PATH 之后追加常见的 Homebrew、用户本地和 nvm 位置，并在开工前逐项预检依赖。可用下列方式模拟精简环境：

```bash
env -i HOME="$HOME" /bin/bash -lc "$HOME/.codex/skills/sleep-well-codex/bin/orchestrator.sh"
```

基本操作：

```bash
# 首次配置
umask 077
mkdir -p ~/sleep-well/codex
cat > ~/sleep-well/codex/config.json <<'JSON'
{ "morning_hour": "07:00", "ntfy_topic": "<换成一串长随机字符>" }
JSON
chmod 700 ~/sleep-well ~/sleep-well/codex
chmod 600 ~/sleep-well/codex/config.json

# 每夜启用 launchd（必须由用户自行执行）
cp ~/.codex/skills/sleep-well-codex/bin/com.user.sleepwell-codex.plist ~/Library/LaunchAgents/
if [ -e ~/sleep-well/codex/state/current-run.json ]; then
  echo '检测到未归档 current-run.json；先核对并归档或改名隔离，暂不重新武装。'
else
  rm -f ~/sleep-well/STOP
  node ~/.codex/skills/sleep-well-codex/lib/cli.mjs terminal-clear
  launchctl load ~/Library/LaunchAgents/com.user.sleepwell-codex.plist
fi

# 当前这一夜收工 / 完全停用：先让编排器观察 STOP 并完成归档
touch ~/sleep-well/STOP
# 若当前没有正在运行的 launchd 跳，手工触发一次收尾；若锁仍被持有，等待在跑跳自行收尾后再检查
bash ~/.codex/skills/sleep-well-codex/bin/orchestrator.sh
test ! -e ~/sleep-well/codex/state/current-run.json
# 只有确认活动状态已经归档后，才做兜底卸载
launchctl unload ~/Library/LaunchAgents/com.user.sleepwell-codex.plist

# 查看状态
cat ~/sleep-well/codex/state/heartbeat
tail -30 ~/sleep-well/codex/logs/orchestrator-*.log
cat ~/sleep-well/codex/morning-report.md
```

`morning_hour` 必须严格使用 24 小时制 `HH:MM`（例如 `07:00`）；非法值会在初始化时失败关闭并告警，不会静默取消 cutoff。

编排器在队列清空、到达 cutoff、看到 STOP 或失败关闭且状态已可靠持久化时，会写入 `TERMINATED` 并自行 `launchctl unload`。归档失败时不落 `TERMINATED`、不卸载并在下一跳重试；在收工阶段无法恢复用户 `pre-push` hook 时也保留 launchd。另一种情形必须区分：若启动阶段发现前一进程遗留的 hook 恢复材料，但因冲突、归属不明或记录/备份无效而无法自动恢复，编排器会告警一次、写入 `TERMINATED` 并自卸载，同时原样保留恢复材料；人工处理后必须重新执行 `terminal-clear` 和 `launchctl load`。这些告警只推送一次，收到后必须检查本机状态与 `current-run.json`，不能假定任务仍在后台或已经卸载。因此 plist 可保留在 `~/Library/LaunchAgents/`，但下一夜仍需重新执行上面的每夜启用流程；它不是安装一次后每天自动运行的定时任务。`terminal-clear` 在未归档的 `current-run.json` 仍存在时会失败关闭，不会清掉 `TERMINATED` 或通知标记。

若没有 STOP、但 node 在已有活动 run 期间缺失或无法运行，编排器会生成明确写有“本夜已有活动运行（未归档）”的最小早报，保留 `current-run.json`，不写 `TERMINATED`、不卸载，并由下一次 launchd 触发重试；固定告警会去重。先核对目标仓库的未提交残留并修复 node，通常无需清除活动状态。若用户已明确设置 STOP，则急停优先：状态与恢复证据仍保留，但本夜会写 `TERMINATED` 并卸载。重新武装前必须先核对目标仓库；状态有效时运行 `node ~/.codex/skills/sleep-well-codex/lib/cli.mjs archive`，状态损坏或需要原样保留时按下文规则改名隔离 `current-run.json`，确认活动文件已不存在后再按每夜启用流程操作。

收到「锁状态异常，无法安全验证持有者」告警时，不要直接删除锁。先用 `pgrep -af 'sleep-well-codex/bin/orchestrator.sh'` 与本机日志确认没有仍在运行的编排器，再用 `ls -la ~/sleep-well/NIGHT.lock` 记录现场，并把整个 `NIGHT.lock` 目录移动到一个人工选择的隔离名称保留证据。下一跳会重新取得锁并清除该告警的去重标记；只要仍可能有实例在跑，就保持锁原样并人工处理。

若 `current-run.json` 无法解析，普通 STOP/finalize 无法归档它。先停止或卸载 launchd，并用 `pgrep -af 'sleep-well-codex/bin/orchestrator.sh'` 确认没有仍在运行的编排器；核对晨报所列日志、各任务仓库的工作树与 `git log` 后，把损坏文件移动到同目录下的 `corrupt-current-run-<人工时间戳>.json.bak` 并保留证据。隔离名不得以 `run-` 开头、也不得以 `.json` 结尾，否则晨报会把它误当作正常归档。不要删除损坏文件。确认仓库残留已妥善处理后，再移除 STOP、执行 `terminal-clear` 并重新 load。

`ntfy_topic` 必须是长随机串：ntfy.sh topic 可被公开订阅。推送只包含经过截断与清洗的任务标题、状态和稳定错误类别；完整路径、堆栈、代码及 findings 正文只写本地日志。

## 队列格式

```markdown
## 修复 foo 的空指针
- id: t1
- repo: ~/Projects/example-repo
- type: bugfix
> 详情写在引用块里，会作为 prompt 传给实现者。
```

`id` 必填且唯一，可以含中文、空格和 `..`，但不能含 `/`、`\` 或 Unicode 控制字符。显示 id 与派生文件名分离：`safe_id` 会编码不安全字节、加可见前缀和 128 位哈希；无法计算哈希时失败关闭。

`repo` 必须是 Git 仓库或 Git worktree 的**顶层目录**，不能指向其中的子目录。本发布版还要求该仓库没有关联其它 linked worktree（linked-worktree checkout 本身也会被拒绝），并且不含子模块 gitlink；见已知限制「Git 元数据护栏只支持单一完整工作树与默认 hooks 目录」。`priority` 和 `files` 若存在必须是整数；空值或非整数会让整份队列拒绝解析，而不是静默采用默认值。

## 运行与恢复模型

待处理任务和可用性退避可跨 launchd 触发恢复。计划内跳退出会在完成事后护栏核验后，把与当前 run 绑定的退出证明原子写入状态；下一进程只消费一次该证明并续跑在途任务。证明缺失、损坏或不属于当前 run 时按进程级异常终止处理：在途任务保守转人工，同一仓库由 `dirtyResidue` 继续阻塞，直至用户核验并清理。正常捕获到的单次 AI 失败仍会先完成事后护栏核验，再按下表中继。

抢到锁的一次调用会持续工作，直到队列清空、到达截止时间、看到 STOP，或两侧 AI 都不可用。launchd 在 job 运行期间会丢弃 interval 触发，不会启动并发副本；文件锁仍用于手工调用和异常并发的防御。

挂起进程不会像崩溃那样释放锁，因此编排器内置分层有界机制：

| 机制 | 行为 |
|---|---|
| `SLEEP_WELL_STARTUP_TIMEOUT`（默认 15 秒） | 在主看门狗武装前，把锁 owner 的 `ps` 探针、终止态 hook 恢复与自卸载限制在独立进程组内 |
| `SLEEP_WELL_AI_TIMEOUT`（1–86400 秒；默认 1800） | 单次 AI 调用超时后终止该调用的独立进程组 |
| `SLEEP_WELL_HANG_LIMIT`（1–87300 秒；默认 2700） | 心跳停滞后，看门狗先终止活动 AI 进程组，再终止编排器后代并让 EXIT trap 清理锁和 hook；若不大于 AI 超时，会自动设为 AI 超时加 900 秒 |
| `SLEEP_WELL_WATCHDOG_POLL`（1–300 秒；默认 30） | 进程内看门狗的轮询间隔；越界值压入范围并记录告警 |
| `SLEEP_WELL_WATCHDOG_GRACE`（3–300 秒；默认 30） | TERM 后升级 KILL 前的宽限期；越界值压入范围并记录告警 |
| 调用轮询心跳 | 长调用期间持续刷新心跳，避免被误判为编排器挂起 |

AI 与 HANG 两个阈值会在开工前校验；非整数或超出表中范围会在任何 AI 调用前失败关闭、写入区分“无活动运行/已有活动运行”的配置错误早报、推送一次固定告警并释放锁，已有活动状态保持待续。POLL 与 GRACE 的非整数会回落默认值，越界值会压入表中范围并记录本机告警。若存在待恢复的 pre-push hook，早报与告警会明确提示修复配置前 `git push` 可能被阻断。若 AI/HANG 配置非法但已有 `STOP`，编排器只为完成急停收尾临时采用安全默认值，仍会归档活动状态；若 node 已缺失，则如实提示活动状态未归档并原样保留，绝不称为“没有活动运行”。活动进程组记录包含 owner PID；陈旧或 owner 不匹配的记录不会被采信。所有 AI 调用都关闭 stdin，避免 CLI 等待附加输入。受保护路径扫描不生成与实际进展无关的合成心跳；若 `find`、哈希或文件系统 I/O 卡死，心跳会变陈旧并由看门狗接管。

## 审修循环

每个任务按以下顺序运行：

`实现（不提交） → 独立审查未提交 diff → 记录并验证 findings → 修复或转人工 → 重新审查 → 零 findings 后 checkpoint`

findings 数量来自适配器产生的结构化 Markdown，并同时校验元信息、逐条标题和处理状态骨架。文件缺失、计数不一致或格式不可信都按审查失败处理，绝不解释为零 findings。

审查适配器应把输出写在目标仓库之外，或写入目标仓库的 `.review/`，且不得修改其它仓库内容。基线检查和 checkpoint 都排除 `.review/`；适配器返回后、任何判定或 checkpoint 前，编排器会核验引用与受保护路径，并比较审查前后的 Git 可见工作内容和索引快照。findings 的规范化真实路径若落在仓库内但不在 `.review/`，会在记录前被拒绝。

高严重度 finding 不自动修复；任务转为 `needs_human`。非高严重度 finding 的自动修复受轮数与停滞判定限制。

## 可用性中继

| 情形 | 动作 |
|---|---|
| Claude 暂时不可用 | 暂缓审查并保留任务状态，下一次 launchd 触发重试 |
| Codex 暂时不可用 | 不取新任务；允许在途任务探测恢复 |
| 两侧都暂时不可用 | 当前调用退出，下次触发重试 |
| 任一侧认证失效 | 收工并推送稳定错误类别，等待人工重新登录 |

某一侧的实际成功调用是恢复证据；成功后清除该侧的不可用标记。

## 护栏

Codex 子进程使用 `workspace-write` 沙箱，关闭 shell 网络访问，并使用隔离的 `CODEX_HOME`。编排器自身以 `umask 077` 保护运行时状态；进入目标仓库的 Codex 子进程重设为常规 `umask 022`，避免把新增源码静默建成 0600/0700。原生网页工具不受 shell 网络沙箱约束，所以隔离配置必须把 `web_search = "disabled"` 放在任何 TOML 表头之前。`bin/probe-native-web.sh` 提供带正对照的人工回归探针，会把调用方的 `CODEX_HOME` 规范化成绝对路径，再为两个探针 home 链接并复验同一登录态；它会发起真实模型调用，因此不属于常规测试。

独立审查适配器不在 Codex 进程沙箱中，而是以当前运行账户的完整权限执行。事后核验只覆盖目标仓库内的内容、索引与 Git 元数据；适配器写入仓库外的 `~/.gitconfig`、shell 启动文件或 launch agent 等既不会被阻止，也不会被检出，后续 Git 命令还可能读取这些变化。只能使用可信适配器；需要更强边界时应使用专用低权限账户或一次性环境。

`pre-push` hook 只作纵深防御，不能阻止 `--no-verify`。编排器会保存、标识并恢复已有 hook；无法确认所有权时失败关闭并保留恢复材料。

每次 Codex 调用后，以及每次独立 Claude 审查适配器返回后，编排器都会在 AI 进程之外核验：

| 核验 | 检测目标 |
|---|---|
| `rev-list <preSha>..HEAD` 为空 | 未授权 commit 或 merge |
| merge/squash 标记不存在 | 未完成或 squash merge |
| `refs/heads` 前后一致 | 分支创建、删除、reset、fast-forward |
| 受保护路径哈希一致 | 合同、法务和凭据类文件变化，包括未跟踪文件及受保护符号链接目标 |
| Codex 回合前后 `.review/` 保留区快照一致 | 实现者在审查保留区隐藏或遗留任何内容 |
| 审查前后 Git 可见内容与索引快照一致 | 独立审查器修改 tracked 或未忽略的 untracked 源码、文件模式或暂存区 |
| Git 默认 hooks/config/安全相关 info 元数据快照一致 | 实现者或审查器安装 hook、filter、fsmonitor，改写 exclude/attributes/sparse-checkout/grafts/对象 alternates；checkpoint 另以 `core.hooksPath=/dev/null` 禁用 hook。`info/refs`、packs、commit-graph 等 Git 后台维护缓存不纳入，避免 auto-gc 假告警 |

任一核验失败，或核验命令本身失败，都会中止整夜并告警。

## 已知限制

1. `workspace-write` 限制仓库外写入，但不限制读取。模型能读取运行账户下任何可读文件；若需更强边界，应使用专用低权限账户或隔离环境。
2. macOS 沙箱允许写临时目录，例如 `/tmp`。
3. 未跟踪的受保护文件会备份到 `~/sleep-well/codex/backups/`，当前没有自动清理策略；凭据副本可能长期累积。
4. `~/sleep-well/codex/logs/` 会保留完整 Codex 输出、审查 stderr 与 findings 副本，可能含仓库路径和代码片段；当前没有自动清理策略，且清理 `.review/` 或 `backups/` 不会清理这些日志。需定期核对并仅删除已确认不再需要的单个日志文件。
5. 文件超出 `SLEEP_WELL_BACKUP_MAX_BYTES` 或备份失败时会告警但不阻止开工。护栏仍能检测变化，但没有可恢复副本。
6. 两个变体的互斥是单向的。只有本变体获取 `NIGHT.lock`，所以不得并发运行。
7. 本变体有进程沙箱与事后仓库核验；`sleep-well` 变体由模型按 SKILL 指令调用 helper，本仓库未提供进程级 PreToolUse hook。
8. 本变体不做 Idle discovery，也不做团队委派；队列为空即收工。
9. 法务关键词只覆盖英文及中日文常见词。其它语言可能漏保护；判定刻意保守，日语 `合同テスト`、源码路径 `contracts/`、`contract*.ts`、`agreement*`、`nda*`、`legal*` 等也可能被当作法务内容。Codex 变体一旦检测到这类路径在任务中变化会中止整夜并自卸载；含这些普通源码路径的仓库不适合无人值守。当前选择安全默认：宁可误保护并提示，也不放过潜在法务文件。
10. `.review/` 是审查适配器的保留命名空间，始终从任务基线、受保护路径快照与 checkpoint 排除，但 Codex 实现/修复回合会单独做前后内容快照；实现者的任何写入都会中止整夜。目标仓库若已跟踪 `.review/` 下的任何文件，编排器会在调用 AI 前把任务转为 `needs_human`；这类仓库不能无人值守运行。编排器不会自动清理适配器留下的审查正文；建议在目标仓库的 `.gitignore` 中忽略 `.review/`，并在确认不再需要审计记录后定期逐项清理，避免被手工 `git add -A` 带入历史。
11. findings 正文是模型生成文本，且可能受被审仓库内容影响，因此是不可信输入。修复轮只把它当作问题证据；原始任务与内置修复提示是唯一授权来源，findings 不能扩大任务范围、权限或允许的操作。
12. 审查适配器的只读内容快照不哈希未命中受保护路径规则的 Git ignored 文件。这避免每轮递归哈希 `node_modules/`、构建与缓存树；若普通 ignored 产物也必须不可变，应在专用低权限账户或一次性隔离环境中运行审查器。
13. 看门狗终止挂起的编排器时，会先冻结并清理已发现的后代，再向根进程发送 TERM 以便 EXIT trap 释放锁并恢复 hook。根进程不能先 STOP，因此在收到 TERM 前仍有一个极窄的再次 fork 窗口；新子进程可能被 reparent 而逃过清理。异常收工后应检查是否仍有属于本夜的 Codex/审查子进程，不要仅凭锁与 hook 已恢复就断言所有写入进程都已退出。
14. 本发布版的 Git 元数据护栏只支持单一完整工作树与默认 hooks 目录。含子模块 gitlink、关联其它 linked worktree、有效配置了自定义 `core.hooksPath`、启用了 `extensions.worktreeConfig`，或仓库本地 `.git/config` 使用 `include.path`/`includeIf` 的任务会在任何 AI 调用前转为 `needs_human`；这些额外 gitdir/配置片段与自定义 hook 位置不做无人值守处理。
15. 独立审查适配器是账户级全权限进程，不受 Codex 沙箱约束；仓库外写入不在事后护栏范围内。被审仓库内容可能影响模型输出，因此应只用可信适配器，并在敏感环境使用专用低权限账户或一次性隔离环境。
16. 归档失败或非 STOP 的活动 run 遇到 node 不可用时，编排器刻意不写 `TERMINATED`、不卸载并继续定期重试；收工阶段的 hook 恢复失败也保留 launchd。明确 STOP 时即使 node 不可用也会保留活动状态、写入 `TERMINATED` 并卸载。启动阶段遇到遗留 hook 的恢复冲突、归属不明或材料无效时同样写入 `TERMINATED` 并卸载，只保留材料等待人工处理和重新 load。对应告警用持久标记去重，只发送一次。

## 共享模块

`queue`、`state`、`guardrails`、`config`、`reviewLoop`、`backup`、`report` 及对应测试是复制型共享文件，发布版本必须逐字节一致。`scripts/check-shared-parity.sh` 负责验证。`findings` 与 `quota` 虽在两侧同名但因读取方式和额度编排职责不同而刻意发散，不进入 parity 检查；`route`、`discovery`、`ics` 只属于 Claude 变体。

同名 guardrail helper 的接入边界不同：本变体把受保护路径判定接入进程外哈希核验；Claude 变体依赖 SKILL 指令主动调用，不能描述为进程级强制。

## 测试与维护

```bash
npm test
```

常规套件包括 Node 单测，以及 `prot-hash`、hook 状态机、看门狗和完整夜班 E2E shell 测试。`probe-native-web.sh` 需要真实模型调用，只在 Codex 升级后单独运行；它使用 `CODEX_HOME`（默认 `~/.codex`），登录态缺失时会在发起调用前明确失败。

共享对等检查只能在同时包含两个变体的**源码仓库根目录**运行：`./scripts/check-shared-parity.sh`。安装后的单个技能目录不包含该脚本，也不具备另一棵源码树。

发布前运行完整测试和共享对等检查。公共 SKILL 只保留当前操作约束；不要追加内部评审日记、个人机器事件记录或未公开项目细节。

本技能以 MIT License 发布；许可证全文见本技能目录内的 `LICENSE`。
