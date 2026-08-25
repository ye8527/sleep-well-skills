#!/usr/bin/env bash
# e2e.test.sh — 用假的 codex / claude-handoff 跑完整一夜，验证编排器的端到端行为。
#
# 前七轮的端到端验证都是临时搭的、没入库，于是每轮只测「这轮刚改的那条路径」——
# 这正是 _prot_hash 与 hook 状态机各自复发五次的同一个结构性原因（R8 收尾）。
#
# 假 codex 必须**看参数行事**（R6 血泪）: 早期的假 codex 对 `mcp list` 自检也执行任务动作，
# 于是开工前仓库就脏了，连着三轮把脚手架 bug 当成代码 bug 查。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; }

TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

SW="$TMPD/sleep-well"; REPO="$TMPD/proj"; REPO2="$TMPD/proj2"; REPO3="$TMPD/proj3"; BIN="$TMPD/bin"
mkdir -p "$SW/codex" "$REPO" "$REPO2" "$BIN"
git -C "$REPO2" init -q .; git -C "$REPO2" config user.email t@t; git -C "$REPO2" config user.name t
printf 'z\n' > "$REPO2/b.js"; git -C "$REPO2" add -A >/dev/null 2>&1; git -C "$REPO2" commit -qm base >/dev/null 2>&1

# ── 被操作的仓库 ────────────────────────────────────────────────────
git -C "$REPO" init -q .
git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
printf 'let x = 1\n' > "$REPO/app.js"
printf 'node_modules/\n' > "$REPO/.gitignore"
mkdir -p "$REPO/node_modules/pkg" "$REPO/cfgdir"; printf 'SECRET\n' > "$REPO/node_modules/pkg/.env"
# 受保护链接指向一个**自身路径不受保护**的未跟踪文件（Codex R12 #3）:
# 护栏会跟随并保护 target，但 target 进不了受保护清单——若备份跳过链接，
# 通过链接写入时护栏会报警却没有任何副本可还原。
printf 'LINKED-SECRET\n' > "$REPO/cfgdir/runtime"
printf 'cfgdir/\n' >> "$REPO/.gitignore"
# 链接在 node_modules/pkg/ 下，回到仓库根要两级——写成 ../ 会解析到 node_modules/cfgdir（悬空）
ln -s ../../cfgdir/runtime "$REPO/node_modules/pkg/.env.link"
printf '#!/bin/sh\necho "USER-OWN-HOOK"\n' > "$REPO/.git/hooks/pre-push"
chmod +x "$REPO/.git/hooks/pre-push"
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm base >/dev/null 2>&1

# ── 假 codex: 按参数分流 ────────────────────────────────────────────
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
  *" mcp list "*) echo "No MCP servers configured"; exit 0 ;;
  *" features "*) exit 0 ;;
esac
# 只有 exec 才真的"干活": 往仓库里加一行，不 commit（编排器负责 checkpoint）
for a in "$@"; do :; done
printf 'let y = 2\n' >> app.js
echo "fake codex: 已实现"
exit 0
FAKE
chmod +x "$BIN/codex"

# ── 假 claude-handoff: 第一次出 1 条 finding，第二次出 0 条 ─────────
cat > "$BIN/review.sh" <<'FAKE'
#!/usr/bin/env bash
repo=""; while [ $# -gt 0 ]; do case "$1" in -C) repo="$2"; shift 2;; *) shift;; esac; done
n="$(cat "$FAKE_REVIEW_COUNTER" 2>/dev/null || echo 0)"
n=$((n+1)); echo "$n" > "$FAKE_REVIEW_COUNTER"
mkdir -p "$repo/.review"
f="$repo/.review/claude-findings-fake-$n.md"
if [ "$n" -eq 1 ]; then
  cat > "$f" <<'MD'
# Claude Review Findings
- findings 条数: 1
- 高严重度: 0

### #1 [中] 变量名不清晰
- 位置: `app.js` 2

## 处理状态
- [ ] #1
MD
else
  cat > "$f" <<'MD'
# Claude Review Findings
- findings 条数: 0
- 高严重度: 0

## 处理状态
MD
fi
echo "FINDINGS_FILE=$f"
exit 0
FAKE
chmod +x "$BIN/review.sh"

# ── 队列与配置 ──────────────────────────────────────────────────────
cat > "$SW/queue.md" <<EOF
## 给 app.js 补一行
- id: t1
- repo: $REPO
- type: small-todo
> 随便加一行。
EOF
printf '{ "morning_hour": "07:00", "ntfy_topic": "" }\n' > "$SW/codex/config.json"

export SLEEP_WELL_ROOT="$SW"
export SLEEP_WELL_CODEX="$BIN/codex"
export SLEEP_WELL_CLAUDE_REVIEW="$BIN/review.sh"
export FAKE_REVIEW_COUNTER="$TMPD/counter"
export SLEEP_WELL_AI_TIMEOUT=60
export SLEEP_WELL_HANG_LIMIT=120
export PATH="$BIN:$PATH"
CLI_PATH="$ROOT_DIR/lib/cli.mjs"

echo "端到端"

# ── 跑一夜 ──────────────────────────────────────────────────────────
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
rc=$?

LOG="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
[ -n "$LOG" ] && ok "产生了运行日志" || bad "没有运行日志"
[ -f "$SW/codex/morning-report.md" ] && ok "生成了早报" || bad "未生成早报"
grep -q 'USER-OWN-HOOK' "$REPO/.git/hooks/pre-push" 2>/dev/null \
  && ok "用户原有 pre-push hook 完好归位" || bad "用户 pre-push hook 未归位（R2 #2 / R8 #6）"
[ -f "$SW/codex/hook-recovery.json" ] && bad "收工后仍留有 hook 恢复状态" || ok "收工后无遗留 hook 状态"
[ -d "$SW/NIGHT.lock" ] && bad "收工后锁未释放" || ok "收工后锁已释放"

# 任务真的被实现并 checkpoint 了
# ⚠️ 不要写 `git log | grep -q`: set -o pipefail 下 grep -q 提前退出会让 git 收到 SIGPIPE，
#    管道退出码 141，断言假失败。（同一个坑在 orchestrator 的 MCP 自检里是真 bug，已修。）
nc="$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 0)"
[ "$nc" -ge 2 ] && ok "任务被 checkpoint（${nc} 个提交）" || bad "无 checkpoint 提交（仅 ${nc} 个）"
grep -q 'let y = 2' "$REPO/app.js" 2>/dev/null && ok "实现内容落到了工作树" || bad "实现内容丢失"
[ -z "$(git -C "$REPO" status --porcelain)" ] && ok "收工后工作树干净（已 checkpoint）" \
                                              || bad "收工后仍有未提交改动"

# 审修循环真的跑了两轮（1 条 finding → 修 → 0 条）
c="$(cat "$TMPD/counter" 2>/dev/null || echo 0)"
[ "$c" -ge 2 ] && ok "审修循环执行了 ${c} 轮（首轮 1 条 finding，次轮 0 条）" \
               || bad "审修循环只跑了 ${c} 轮，未验证修复回路"

# 被忽略目录里的凭据没被动过 → 不应误报
grep -q 'SECRET' "$REPO/node_modules/pkg/.env" && ok "被忽略目录内的 .env 未被改动" || bad ".env 被改动"
printf '%s' "$LOG" | grep -q '护栏核验失败\|受保护路径' && bad "无改动却触发护栏告警（误报）" \
                                                       || ok "无改动时不误报护栏"

# 被忽略的受保护文件必须**被备份**（Codex R11 收尾 / 自查 T-4）:
# git 覆盖不到未跟踪文件，没有备份就只能「检出被改、无法还原」。
BAKROOT="$SW/codex/backups"
if [ -f "$BAKROOT/backup-manifest.jsonl" ]; then
  ok "生成了备份清单"
  grep -q '\.env' "$BAKROOT/backup-manifest.jsonl" && ok "被忽略的 .env 已入备份" \
                                                   || bad "被忽略的 .env 未入备份"
  grep -q 'cfgdir/runtime' "$BAKROOT/backup-manifest.jsonl" \
    && ok "受保护链接所指的未跟踪目标已入备份（R12 #3）" \
    || bad "受保护链接的目标未备份——护栏会报警却无副本可还原（R12 #3 回归）"
  # 备份内容必须是**改动前**的原文
  bk="$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).find(e=>/\.env$/.test(e.original));process.stdout.write(l?l.backupPath:"")' "$BAKROOT/backup-manifest.jsonl" 2>/dev/null)"
  [ -n "$bk" ] && [ -f "$bk" ] && grep -q 'SECRET' "$bk" \
    && ok "备份内容是改动前的原文（可用于还原）" || bad "备份文件缺失或内容不对: [$bk]"
else
  bad "没有生成备份清单——backup.mjs 又没接线（T-4 回归）"
fi
# 已跟踪文件不该被重复备份（git 兜底）
if [ -f "$BAKROOT/backup-manifest.jsonl" ]; then
  grep -q 'app\.js' "$BAKROOT/backup-manifest.jsonl" && bad "已跟踪文件被无谓备份" \
                                                     || ok "已跟踪文件不重复备份"
fi

# ── 超时路径: 假 codex 卡死，必须被 KILL 且不无限占锁 ───────────────
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
sleep 900
FAKE
chmod +x "$BIN/codex"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
cat > "$SW/queue.md" <<EOF
## 会卡死的任务
- id: t2
- repo: $REPO
- type: small-todo
> x
EOF
export SLEEP_WELL_AI_TIMEOUT=5
s=$(date +%s)
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
el=$(( $(date +%s) - s ))
# 断言要**能区分设定值与默认值**: 设 5s 就该在 5s 量级返回。原来断言 <120s，
# 即使超时被静默抬到 60s 也照样通过——那样它测不出参数有没有生效。
[ "$el" -lt 30 ] && ok "codex 卡死时 ${el}s 内被超时终止（设定 5s，量级相符）" \
                 || bad "超时未按设定值生效: 设 5s 却用了 ${el}s"
[ -d "$SW/NIGHT.lock" ] && bad "超时后锁未释放" || ok "超时后锁已释放"
grep -q 'USER-OWN-HOOK' "$REPO/.git/hooks/pre-push" 2>/dev/null \
  && ok "超时路径下用户 hook 仍完好" || bad "超时路径下用户 hook 丢失"

# ── 额度中继: fix-only 时不得取新任务（Codex R12 范围外提醒）──────────
# 此前 decideHop 的 defer-review / fix-only 只存在于注释里，主循环照样取新任务
# 并去调那个已知不可用的一侧——SKILL.md 承诺的行为根本没实现。
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
echo "rate limit exceeded" >&2; exit 1
FAKE
chmod +x "$BIN/codex"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
cat > "$SW/queue.md" <<EOF
## 新任务甲
- id: q1
- repo: $REPO
- type: small-todo
> x

## 新任务乙
- id: q2
- repo: $REPO2
- type: small-todo
> y
EOF
export SLEEP_WELL_AI_TIMEOUT=60
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1      # 第一跳: codex 报额度耗尽
rm -f "$SW/codex/TERMINATED"; rm -rf "$SW/NIGHT.lock"
# ⚠️ 三处让这条断言曾经是**假绿**（Codex R13 #4）:
#   1. 第一跳排了 5 分钟退避，紧接着的第二跳在 retry-due 就退出了，**根本没进 fix-only 分支**
#   2. 日志是累加的，grep 能被第一跳的消息满足
#   3. `CALLED <= 1` 放行了一次不该有的调用
# 逐条堵掉: 清退避 / 清空日志 / 断言恰好 0 次。
node "$CLI_PATH" backoff-clear >/dev/null 2>&1 || true
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
# ⚠️ 要测的是「不取**新**任务」。在途任务的重试是**有意保留**的——它正是探测 codex
#    是否恢复的手段（Codex R13 #1 就靠它把可用性置回 ok）。所以先把在途的 q1 落地，
#    让 next-task 只剩一个 pending 的 q2，这时「0 次 exec」才是对 fix-only 的真断言。
node "$CLI_PATH" advance q1 needs_human >/dev/null 2>&1 || true
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
n="$(cat "$CALLS" 2>/dev/null || echo 0)"; echo $((n+1)) > "$CALLS"
echo "rate limit exceeded" >&2; exit 1
FAKE
chmod +x "$BIN/codex"
export CALLS="$TMPD/codex-calls"; echo 0 > "$CALLS"
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1      # 第二跳: 已知 codex 不可用
CALLED="$(cat "$CALLS" 2>/dev/null || echo 0)"
LOG2="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
printf '%s' "$LOG2" | grep -q '不取新任务\|codex 不可用' \
  && ok "codex 不可用时记录了「不取新任务」" \
  || bad "codex 不可用时未走 fix-only 分支（额度中继未实现）"
[ "$CALLED" = "0" ] && ok "codex 不可用时对它的 exec 调用为 0 次（严格断言）" \
                    || bad "codex 已知不可用却仍调用了 ${CALLED} 次"

# ── 单侧故障不得结束本跳（R13 符合性扫查: 与「一跳工作到收工」矛盾）────
# claude 挂了，codex 正常: 本跳应继续推进（defer-review 接管），而不是白等 5 分钟。
cat > "$BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case " $* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'let z = 3\n' >> "$(ls *.js 2>/dev/null | head -1)" 2>/dev/null || true
exit 0
FAKE
chmod +x "$BIN/codex"
cat > "$BIN/review.sh" <<'FAKE'
#!/usr/bin/env bash
echo "CLAUDE_UNAVAILABLE (quota)" >&2; exit 1
FAKE
chmod +x "$BIN/review.sh"
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
cat > "$SW/queue.md" <<EOF
## 甲
- id: s1
- repo: $REPO
- type: small-todo
> x

## 乙
- id: s2
- repo: $REPO2
- type: small-todo
> y
EOF
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
LOG3="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
printf '%s' "$LOG3" | grep -q '本跳继续' \
  && ok "claude 单侧故障后本跳继续（不再白等一整跳）" \
  || bad "单侧故障仍直接结束本跳（与「一跳工作到收工」矛盾）"
# 两个任务都应被实现过（第二个证明循环确实继续了）
# ⚠️ 数「实现开始」的行数不辨任务（Codex R14 #7）: s1 被重复实现两次而 s2 从未启动，
#    这条断言照样通过。改为**按任务 ID** 核对，并直接检查第二个仓库的产物。
printf '%s' "$LOG3" | grep -q '\[s1\] 实现开始' && ok "任务 s1 被实现" || bad "任务 s1 未被实现"
printf '%s' "$LOG3" | grep -q '\[s2\] 实现开始' \
  && ok "任务 s2 也被实现（证明循环确实继续到了第二个任务）" \
  || bad "任务 s2 从未启动，循环没继续"
# ⚠️ 「实现开始」是**调用 codex 之前**打的日志（Codex R15 #3）: 让 codex_step 对 s2
#    直接返回成功而不真调 codex，这条断言照样通过。必须核对第二个仓库的**实际产物**。
grep -q 'let z = 3' "$REPO2"/*.js 2>/dev/null \
  && ok "第二个仓库确有产物（不是只打了日志）" \
  || bad "第二个仓库没有任何产物——s2 实际未被实现"

# ── 内部错误退出必须推送（R13 符合性扫查）────────────────────────────
rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
# ⚠️ 写坏 config 只会让 `init` 失败、走既有的「夜班未开工」推送，**根本进不了 hop_fail**
#    （Codex R14 #6——他实测把 hop_fail 改成静默退出后 24 条仍全过）。
#    要真正触发它，得让 init **成功**之后的 cli 调用失败: 先正常跑起来建好状态，
#    再把状态文件写坏，这样 availability-get / next-task 会失败而 init 已经过了。
# 写坏状态文件不行——`init` 会先失败，走的是既有的「夜班未开工」路径。
# 要真正进 hop_fail，得让 init **成功**而后续某个 cli 调用失败: 用 PATH 影子 node
# 做定点失败注入（只让 next-task 失败，其余原样透传）。这是 Codex 要求的「真实失败注入」。
# ⚠️ 必须在造影子**之前**取真实路径（Codex R15 #5）: $BIN 已在 PATH 首位，
#    造完再 `command -v node` 只是碰巧命中 bash 的 hash 缓存；`bash +h`、
#    之前执行过 `hash -r`、或测试重排都会让 REAL_NODE 指向影子自身 → 无限递归。
export REAL_NODE="$(command -v node)"
INJECT_MSG="injected-next-task-failure-$$"
cat > "$BIN/node" <<FAKENODE
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "next-task" ]; then echo "$INJECT_MSG" >&2; exit 1; fi
done
exec "$REAL_NODE" "\$@"
FAKENODE
chmod +x "$BIN/node"
rm -f "$SW/codex/TERMINATED"; rm -rf "$SW/NIGHT.lock"
: > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
rm -f "$BIN/node"
LOG4="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
printf '%s' "$LOG4" | grep -q '本跳异常退出' \
  && ok "内部错误走 hop_fail 并留下告警（不再一声不吭）" \
  || bad "内部错误退出时未经 hop_fail——用户早上既无早报也无告警"
printf '%s' "$LOG4" | grep -q 'PUSH\[⚠️ 夜班异常退出\]' \
  && ok "hop_fail 确实发出了推送" || bad "hop_fail 未发推送"
# ⚠️ 只匹配标题不够（Codex R15 #4）: 把 hop_fail 正文换成任意文本，26 条照样全过——
#    用户会收到同名告警却没有可诊断的原因。断言正文必须携带本次失败的原因。
printf '%s' "$LOG4" | grep 'PUSH\[⚠️ 夜班异常退出\]' | grep -q '取任务失败' \
  && ok "异常推送正文携带了失败原因" \
  || bad "异常推送正文不含失败原因（用户收到告警但无从诊断）"


# ── codex_step 必须真的调用护栏（Codex R15 #2）─────────────────────────
# 他实测把 codex_step 里两处 guard_verify 都换成 true，26 条 E2E 仍全绿——
# 意味着以后**删掉集中式护栏实现**照样能拿到全绿。这里注入两种情形:
#   (a) codex 成功但改了受保护文件 → 必须中止整夜
#   (b) codex 非零退出且改了受保护文件 → 同样必须中止（R13 补的那个洞）
# ⚠️ 上一版只注入了「改受保护文件」这一条分支（Codex R17 #1）: 他把 rev-list、
#    merge 标记、分支切换、for-each-ref 四项核验**全部删掉**，149 项照样全绿。
#    五项核验必须各有独立注入——「加了失败注入」不等于「护栏被覆盖」。
#    每个用例声明: 动作 → 期望在日志里看到的**那一句**。
guard_case() {   # $1=用例名 $2=fake codex 里要执行的动作 $3=期望的日志片段
  rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
  rm -rf "$REPO3"; mkdir -p "$REPO3"
  git -C "$REPO3" init -q .; git -C "$REPO3" config user.email t@t; git -C "$REPO3" config user.name t
  printf 'node_modules/\n' > "$REPO3/.gitignore"
  mkdir -p "$REPO3/node_modules/p"; printf 'ORIGINAL\n' > "$REPO3/node_modules/p/.env"
  printf 'x\n' > "$REPO3/a.js"
  git -C "$REPO3" add -A >/dev/null 2>&1; git -C "$REPO3" commit -qm base >/dev/null 2>&1
  cat > "$BIN/codex" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
cd "$REPO3" || exit 1
$2
exit 0
FAKE
  chmod +x "$BIN/codex"
  cat > "$SW/queue.md" <<EOF
## 护栏注入
- id: gc
- repo: $REPO3
- type: small-todo
> x
EOF
  : > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
  local lg; lg="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
  local miss=""
  printf '%s' "$lg" | grep -q "$3" || miss="${miss}[未报出「$3」]"
  printf '%s' "$lg" | grep -q '收工: 护栏违规，中止整夜' || miss="${miss}[未中止整夜]"
  [ -z "$miss" ] && ok "护栏注入·$1" || bad "护栏注入·$1 未按预期: ${miss}"
}

guard_case "未授权提交"   'printf "sneaky\n" >> a.js; git add -A >/dev/null 2>&1; git commit -qm sneaky >/dev/null 2>&1' '新提交'
guard_case "merge 标记"   'printf "merged\n" > .git/MERGE_MSG' 'MERGE_MSG'
guard_case "分支引用变化" 'git branch evil-branch >/dev/null 2>&1' '本地分支引用发生变化'
guard_case "切换分支"     'git checkout -q -b other >/dev/null 2>&1' '当前分支由'

# 「核验命令自身失败」与「检出违规」是两条不同的路（Codex R18 #1）:
# 前者是护栏不可用，必须报「核验不可得」并中止，而不是当成「未检出违规」放行。
# 用 PATH 包装 git: 快照阶段放行，见到 marker 之后让指定子命令失败。
guard_cmdfail_case() {   # $1=用例名 $2=要让其失败的 git 子命令 $3=期望日志片段
  rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
  rm -rf "$REPO3"; mkdir -p "$REPO3"
  git -C "$REPO3" init -q .; git -C "$REPO3" config user.email t@t; git -C "$REPO3" config user.name t
  printf 'x\n' > "$REPO3/a.js"; git -C "$REPO3" add -A >/dev/null 2>&1; git -C "$REPO3" commit -qm base >/dev/null 2>&1
  REAL_GIT="$(command -v git)"
  MARKER="$TMPD/cmdfail-marker"; rm -f "$MARKER"
  cat > "$BIN/git" <<GITW
#!/usr/bin/env bash
# 只在 marker 存在后让目标子命令失败——快照阶段必须成功，否则测的是快照失败而非核验失败
if [ -f "$MARKER" ]; then
  for a in "\$@"; do
    if [ "\$a" = "$2" ]; then echo "injected git failure" >&2; exit 1; fi
  done
fi
exec "$REAL_GIT" "\$@"
GITW
  chmod +x "$BIN/git"
  cat > "$BIN/codex" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
touch "$MARKER"          # 快照已过，从这里开始让核验命令失败
printf 'y\n' >> "$REPO3/a.js"
exit 0
FAKE
  chmod +x "$BIN/codex"
  cat > "$SW/queue.md" <<EOF
## 核验失败注入
- id: cf
- repo: $REPO3
- type: small-todo
> x
EOF
  : > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
  local lg; lg="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
  rm -f "$BIN/git" "$MARKER"
  local miss=""
  printf '%s' "$lg" | grep -q "$3" || miss="${miss}[未报出「$3」]"
  printf '%s' "$lg" | grep -q '护栏违规，中止整夜' || miss="${miss}[未中止整夜]"
  [ -z "$miss" ] && ok "核验命令失败·$1" || bad "核验命令失败·$1 未按预期: ${miss}"
}

guard_cmdfail_case "for-each-ref 出错" "for-each-ref" "护栏核验失败: for-each-ref 出错"
guard_cmdfail_case "rev-list 出错"     "rev-list"     "护栏核验失败: rev-list 出错"

for CASE in success failure; do
  rm -rf "$SW/codex/state" "$SW/codex/TERMINATED" "$SW/NIGHT.lock"
  rm -rf "$REPO3"; mkdir -p "$REPO3"
  git -C "$REPO3" init -q .; git -C "$REPO3" config user.email t@t; git -C "$REPO3" config user.name t
  printf 'node_modules/\n' > "$REPO3/.gitignore"
  mkdir -p "$REPO3/node_modules/p"; printf 'ORIGINAL\n' > "$REPO3/node_modules/p/.env"
  printf 'x\n' > "$REPO3/a.js"
  git -C "$REPO3" add -A >/dev/null 2>&1; git -C "$REPO3" commit -qm base >/dev/null 2>&1
  if [ "$CASE" = success ]; then EXITCODE=0; else EXITCODE=1; fi
  cat > "$BIN/codex" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" mcp list "*) echo "No MCP servers configured"; exit 0 ;; esac
printf 'TAMPERED\n' > "$REPO3/node_modules/p/.env"
exit $EXITCODE
FAKE
  chmod +x "$BIN/codex"
  cat > "$SW/queue.md" <<EOF
## 护栏注入
- id: g1
- repo: $REPO3
- type: small-todo
> x
EOF
  : > "$(ls "$SW/codex/logs/"orchestrator-*.log 2>/dev/null | head -1)" 2>/dev/null || true
  bash "$ROOT_DIR/bin/orchestrator.sh" >/dev/null 2>&1
  LOG5="$(cat "$SW/codex/logs/"orchestrator-*.log 2>/dev/null)"
  # ⚠️ 断言必须落在**具体的违规原因 + 终止状态**上（Codex R16 #1）:
  #    原来只 grep「护栏」二字——他把 guard_verify 换成「只打一行含『护栏』的日志然后
  #    返回成功」，30 条照样全过。我上一轮验检出能力时 crippled 版把日志也去掉了，
  #    所以没暴露。**关键词匹配不是断言。**
  MISS=""
  printf '%s' "$LOG5" | grep -q '护栏违规: 受保护路径内容变化' || MISS="${MISS}[无具体违规原因]"
  printf '%s' "$LOG5" | grep -q '收工: 护栏违规，中止整夜' || MISS="${MISS}[未中止整夜]"
  [ -f "$SW/codex/TERMINATED" ] || MISS="${MISS}[未落 TERMINATED]"
  # 被改的凭据必须仍是被改后的样子（护栏是检测不是回滚），且任务不得被 checkpoint
  [ "$(git -C "$REPO3" rev-list --count HEAD 2>/dev/null || echo 0)" = "1" ] || MISS="${MISS}[违规后仍产生了 checkpoint]"
  if [ -z "$MISS" ]; then
    ok "codex ${CASE} 且改了受保护文件 → 护栏报出确切违规并中止整夜"
  else
    bad "codex ${CASE} 改了受保护文件，护栏未按预期动作: ${MISS}"
  fi
done

printf '\ne2e: pass %d / fail %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
